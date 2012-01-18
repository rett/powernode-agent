require 'rubygems'
require 'bundler/setup'
require 'aws'
require 'beetle'
require 'benchmark'
require 'eventmachine'
require 'json'
require 'net/ssh'
require 'net/sftp'
require 'restclient'
require 'tmpdir'

APP_CONFIG = YAML.load_file(File.join(File.dirname(__FILE__), "config.yml"))

$jobs = Hash.new
EM.threadpool_size = APP_CONFIG['queue_size']

class Handler < Beetle::Handler
  def process
    @params = JSON.parse(message.data)
    @operation = @params['operation']
    @identifier = "#{@params['node']['identifier']}_#{@operation}"
    if $jobs[@identifier].nil?
      puts "Queueing operation: #{@identifier}"
      EM.defer(operation_start, operation_finish)
    else
      puts "Operation skipped: #{@identifier}"
    end
  end

  def operation_start
    $jobs[@identifier] = proc {
      puts "Operation started: #{@identifier}"
      begin
        @node_parent = @params['parent_url']
        @node_platform = @params['node_platform']
        @node_platform_resource = RestClient::Resource.new("#{@node_parent}/manage/platform/#{@node_platform['identifier']}",
                                                           @params['identifier'],
                                                           @params['passphrase'])
        @node_response = JSON.parse(@node_platform_resource["nodes/#{@params['node']['identifier']}"].get(:accept => :json))
        @node = @node_response['node']
        @node_template = @node_response['node_template']
        @node_instances = @node_response['node_instances']
        @node_module_categories = @node_response['node_module_categories']
        @node_modules = @node_response['node_modules']
        @node_provider = @node_response['node_provider']
        @node_template = @node_response['node_template']
        @node_module_updates = @node_response['node_module_updates']
        self.send("node_#{@operation}") if self.respond_to?("node_#{@operation}")
        puts "Operation finished: #{@identifier}"
      rescue Exception => e
        puts "Exception: #{e.message}"
      end
      @identifier
    }
  end

  def operation_finish
    proc {|result|
      $jobs.delete(result) if result && $jobs.include?(result)
    }
  end

  def node_test_operation
    sleep 10
  end

  def node_update_status
    instance_variance = @node['instances'] - @node_instances.count

    puts "Updating node: #{@node['identifier']}..."
    @node_platform_resource["nodes/#{@node['identifier']}"].post(:last_update => Time.now)
    @ec2 = Aws::Ec2.new(@node_provider['aws_access_key'],
                        @node_provider['aws_secret_key'],
                        {:endpoint_url => @node_provider['aws_url']})
    if @node['enabled'] == true
      node_check_instances
      if instance_variance > 0
        puts "Launching #{instance_variance} instances..."
        node_launch_instances(instance_variance)
      elsif instance_variance < 0
        instance_variance *= -1
        puts "Destroying #{instance_variance} instances..."
        node_destroy_instances(instance_variance)
      else
        puts "Correct number of instances running."
      end
      if !@node['node_module_updates'].nil?
        @node['node_module_updates'].each do |node_module_update|
          node_module = @node_modules.find {|m| m['id'] == node_module_update}
          puts "Node module update: #{node_module_update}"
          node_commit_node_module(node_module)
        end
      end
      node_trigger_update if @node['trigger_update']
    else
      if @node_instances.count > 0
        puts "Node disabled, destroying #{@node_instances.count} instances..."
        node_destroy_instances(@node_instances.count)
      end
    end
    puts "Status update complete."
  end

  def node_trigger_update
    if @node['enabled'] == true
      @node_platform_resource["nodes/#{@node['identifier']}"].post(:last_update => Time.now, :trigger_update => true)
      @node_instances.each do |node_instance|
        if node_instance['last_update'].nil? || Time.parse(node_instance['last_update']) < @node_platform['update_interval'].seconds.ago
          puts "Triggering update on instance: #{node_instance['aws_instance']}..."
          node_instance['last_update'] = Time.now
          @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(:node_instance => node_instance)
          begin
            session = Net::SSH.start(node_instance['ip_private'],
                                     @node_template['admin_user'],
                                     :key_data => node['key'],
                                     :paranoid => false)
          rescue Exception => e
            puts "Exception: #{e.message}"
          end
          if session
            @node_module_categories.each do |c|
              begin
                session.exec!("sudo ipn -auv #{c} all")
              rescue Exception => e
                puts "Exception: #{e.message}"
              end
            end
          end
        end
      end
    end
  end

  def node_check_instances
    puts "Checking instances for #{@node['identifier']}..."
    begin
      aws_instances = @ec2.describe_instances(@node_instances.map {|i| i['aws_instance']})
    rescue Exception => e
      puts "Exception: #{e.message}"
    end
    @node_instances.each do |node_instance|
      if aws_instance = aws_instances.find {|i| i[:aws_instance_id] == node_instance['aws_instance']}
        node_instance.delete("id")
        node_instance.delete("node_id")
        node_instance['error_count'] = 0
        node_instance['ip_private'] = aws_instance[:private_dns_name]
        node_instance['state'] = aws_instance[:aws_state]
      else
        if node_instance['error_count'] < 3
          node_instance['error_count'] += 1
        else
          @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(:node_instance => node_instance, :operation => "destroy")
        end
      end
    end
    begin
      @node_platform_resource["nodes/#{@node['identifier']}/instances.json"].post(:node_instances => @node_instances.to_json)
    rescue Exception => e
      puts "Exception: #{e.message}"
    end
  end

  def node_commit_node_module(node_module)
    puts "Committing module #{node_module['identifier']} for node #{@node['identifier']}..."
    node_instance = @node_instances.find {|i| i['primary'] == true}

    if !node_instance.nil? && !node_module['spec'].empty?
      tmp_dir = Dir.mktmpdir
      FileUtils.chmod(0755, tmp_dir)

      Net::SFTP.start(node_instance['ip_private'], @node_template['admin_user'], :key_data => @node['key'], :paranoid => false) do |session|
        node_module['spec'].each_line do |file|
          file.chomp!
          target_path = tmp_dir + file
          begin
            case session.lstat!(file).type
            when 1
              # File discovered, create dir and download.
              FileUtils.mkdir_p(target_path[0..target_path.rindex("/")])
              session.download!(file, target_path)
            when 2
              # Directory discovered, create dir.
              FileUtils.mkdir_p(target_path)
            when 3
              # Symlink discovered, create dir and symlink.
              FileUtils.mkdir_p(target_path[0..target_path.rindex("/")])
              FileUtils.ln_s(session.realpath!(file).name, target_path)
            end
          rescue Exception => e
            puts "Exception: #{e} on file: #{file}"
          end
          begin
            FileUtils.chown(session.lstat!(file).attributes[:uid], session.lstat!(file).attributes[:gid], target_path)
            FileUtils.chmod(session.lstat!(file).attributes[:permissions], target_path)
          rescue Exception => e
            puts "Exception: #{e.message}"
          end
        end
      end
      tmp_module = Tempfile.new("module-#{@node['id']}")
      tmp_module.close
      system("mksquashfs #{tmp_dir} #{tmp_module.path} -noappend")
      @node_platform_resource["nodes/#{@node['identifier']}/modules/#{node_module['identifier']}.json"].post(
        :accept => :json,
        :data => File.open(tmp_module),
        :multipart => true,
        :content_type => "application/octet-stream")
      FileUtils.remove_entry_secure tmp_dir
      puts "Commit complete."
    elsif node_instance.nil?
      puts "Commit aborted: No primary node instance found!"
    else
      puts "Commit aborted: No module specification!"
    end
  end

  def node_destroy_instances(count = 1)
    puts "Destroying #{count} instances for #{@node['identifier']}..."
    count.times do |n|
      node_instance = @node_instances.reverse[n]
        begin
          @ec2.terminate_instances([node_instance['aws_instance']])
        rescue Exception => e
          puts "Exception: #{e.message}"
        end
        begin
          @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(:node_instance => node_instance, :operation => "destroy")
        rescue Exception => e
          puts "Exception: #{e.message}"
        end
    end
  end

  def node_launch_instances(count = 1)
    puts "Loading key for node: #{@node['identifier']}..."
    keypair_name = @node['identifier']
    begin
      keys = @ec2.describe_key_pairs([keypair_name])
    rescue Exception => e
      puts "Exception: #{e.message}"
    end
    if !keys[0].nil? && keys[0][:aws_fingerprint] == @node['key_fingerprint']
      key = keys[0]
    else
      begin
        @ec2.delete_key_pair(keypair_name)
      rescue Exception => e
        puts "Exception: #{e.message}"
      end
      begin
        key = @ec2.create_key_pair(keypair_name)
      rescue Exception => e
        puts "Exception: #{e.message}"
      end

      if key
        @node_platform_resource["nodes/#{@node['identifier']}"].post(:accept => :json,
                                                                     :aws_material => key[:aws_material],
                                                                     :aws_fingerprint => key[:aws_fingerprint])
      end
    end

    user_data = <<-END
  PARENT=#{@node_parent}
  IDENTIFIER=#{@node['identifier']}
  PASSPHRASE=#{@node['passphrase']}
    END

    puts "Launching #{count} instances for #{@node['identifier']}..."
    count.times do
      begin
        aws_instance = @ec2.launch_instances(@node_template['aws_image'],
                                             :kernel_id => @node_template['aws_kernel'],
                                             :ramdisk_id => @node_template['aws_ramdisk'],
                                             :aws_availability_zone => @node_template['aws_availability_zone'],
                                             :instance_type => @node_template['aws_instance_type'],
                                             :key_name => keypair_name,
                                             :user_data => user_data)[0]
      rescue Exception => e
        puts "Exception: #{e.message}"
      end
      node_instance = Hash.new
      node_instance['aws_instance'] = aws_instance[:aws_instance_id]
      node_instance['ip_private'] = aws_instance[:private_dns_name]
      node_instance['state'] = aws_instance[:aws_state]
      node_instance['start_time'] = aws_instance[:aws_launch_time]
      begin
        @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(:node_instance => node_instance)
      rescue Exception => e
        puts "Exception: #{e.message}"
      end
    end
  end
end

Beetle.config do |config|
  config.user = APP_CONFIG['amqp_user'] || "guest"
  config.password = APP_CONFIG['amqp_password'] || "guest"
  config.servers = APP_CONFIG['amqp_servers'] || "localhost:5672"
  config.system_name = APP_CONFIG['amqp_system_name'] || "system"
  config.additional_subscription_servers = APP_CONFIG['amqp_additional_subscription_servers'] || ""
  config.vhost = APP_CONFIG['amqp_vhost'] || "/"
  config.redis_server = APP_CONFIG['redis_server'] || "localhost:6379"
  config.redis_servers = APP_CONFIG['redis_servers'] || ""
  config.redis_db = APP_CONFIG['redis_db'] || 4
  config.redis_failover_timeout = APP_CONFIG['redis_failover_timeout'] || 180.seconds
  config.redis_configuration_master_retries = APP_CONFIG['redis_configuration_master_retries'] || 3
  config.redis_configuration_master_retry_interval = APP_CONFIG['redis_configuration_master_retry_interval'] || 10.seconds
  config.redis_configuration_client_timeout = APP_CONFIG['redis_configuration_client_timeout'] || 5.seconds
  config.redis_configuration_client_ids = APP_CONFIG['redis_configuration_client_ids'] || ""
end

queue = APP_CONFIG['amqp_queue']
beetle = Beetle::Client.new
beetle.configure do |config|
  config.queue queue
  config.message queue
  config.handler(queue, Handler)
end

beetle.listen do
  puts "Started Manager."
  trap("INT") do
    beetle.stop_listening
    puts "Stopped Manager."
  end
end
