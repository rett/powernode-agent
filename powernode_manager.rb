require 'aws'
require 'benchmark'
require 'rubygems'
require 'bundler'
require 'restclient'
require 'beetle'
require 'json'
require 'net/ssh'
require 'net/sftp'
require 'tmpdir'

APP_CONFIG = YAML.load_file(File.join(File.dirname(__FILE__), "config.yml"))

Beetle.config do |config|
  config.logger.level = Logger::DEBUG
  config.servers = APP_CONFIG['beetle_servers']
  config.redis_server = APP_CONFIG['redis_server']
  config.redis_servers = APP_CONFIG['redis_servers']
end

$beetle = Beetle::Client.new
$beetle.register_queue(:powernode)
$beetle.register_message(:powernode)

$beetle.register_handler(:powernode, :exceptions => 1, :delay => 0) do |message|
  params = JSON.parse(message.data)
  operation = params["operation"]
  fork { self.send(operation, params) } if self.respond_to?(operation)
end

def self.node_trigger_update(params)
  node = params['node']
  node_resource = RestClient::Resource.new(APP_CONFIG['node_url'],
                                           node['identifier'],
                                           node['passphrase'])
  node_resource.post(:accept => :json,
                     :trigger_update => nil,
                     :operation => "update")
  node_response = JSON.parse(node_resource.get(:accept => :json))

  node_instances = node_response['node_instances']
  node_module_categories = node_response['node_module_categories']
  node_template = node_response['node_template']

  if node['enabled'] == true
    node_instances.each do |node_instance|
      if node_instance['last_update'].nil? || Time.parse(node_instance['last_update']) < APP_CONFIG['poll_interval'].seconds.ago
        puts "Triggering update on instance: #{node_instance['aws_instance']}..."
        node_instance['last_update'] = Time.now
        node_resource['instance'].post(:accept => :json,
                                       :node_instance => node_instance,
                                       :operation => "update")
        begin
        session = Net::SSH.start(node_instance['ip_private'],
                                 node_template['admin_user'],
                                 :key_data => node['key'],
                                 :paranoid => false)
        rescue
        end
        if session
          node_module_categories.each do |c|
            begin
              session.exec!("sudo ipn -auv #{c} all")
            rescue
            end
          end
        end
      end
    end
  end
end

def self.node_update_status(params)
  node = params['node']
  node_resource = RestClient::Resource.new(APP_CONFIG['node_url'],
                                           node['identifier'],
                                           node['passphrase'])

  node_response = JSON.parse(node_resource.get(:accept => :json))
  node_instances = node_response['node_instances']
  node_platform = node_response['node_platform']
  node_template = node_response['node_template']
  instances = node['instances'] - node_response['node_instances'].count

  @ec2 = Aws::Ec2.new(node_platform['aws_access_key'],
                      node_platform['aws_secret_key'],
                      {:endpoint_url => node_platform['aws_url']})

  if node['enabled'] == true
    if instances > 0
      puts "Not enough instances, launching #{instances} instances..."
      launch_instances(node, node_template, node_platform, instances)
    elsif instances < 0
      instances *= -1
      puts "Too many instances, destroying #{instances} instances..."
      destroy_instances(node, node_instances, node_platform, instances)
    else
      puts "Correct number of instances running."
    end
  else
    if node_instances.count > 0
      puts "Node disabled, destroying #{node_instances.count} instances..."
      destroy_instances(node, node_instances, node_platform, node_instances.count)
    end
  end

  # Todo: Update node status.

  node_instances.each do |node_instance|
    aws_instance = @ec2.describe_instances([node_instance['aws_instance']])[0]
    begin
      node_resource['instance'].post(:accept => :json,
                                     :aws_instance => aws_instance,
                                     :operation => "update")
    rescue
    end
  end

  puts "Status update complete."
end

def self.node_module_commit(params)
  node = params['node']
  node_instance = params['node_instance']
  node_module_category = params['node_module_category']
  node_module_identifier = params['node_module_identifier']
  node_module_spec = params['node_module_spec']
  node_platform = params['node_platform']

  if node_instance['state'] == "active"
    puts "Commiting module #{node_module_identifier} from node #{node['identifier']}..."

    node_module_resource = RestClient::Resource.new(APP_CONFIG['module_url'],
                                                    node['identifier'],
                                                    node['passphrase'])

    tmp_dir = Dir.mktmpdir
    FileUtils.chmod(0755, tmp_dir)  

    Net::SFTP.start(node_instance['ip_private'], params['admin_user'], :key_data => node['key'], :paranoid => false) do |session|    
      node_module_spec.each_line do |file|
        file.chomp!
        target_path = tmp_dir + file
        puts "Target Path: " + target_path
        case session.lstat!(file).type
        when 1
          # File discovered, create dir and download.
          FileUtils.mkdir_p(target_path[0..target_path.rindex('/')])
          session.download!(file, target_path)
        when 2
          # Directory discovered, create dir.
          FileUtils.mkdir_p(target_path)
        when 3
          # Symlink discovered, create dir and symlink.
          FileUtils.mkdir_p(target_path[0..target_path.rindex('/')])
          FileUtils.ln_s(session.realpath!(file).name, target_path)
        end

        #path = file
        #while path.rindex('/') > 0 do
        #  path = path[0..path.rindex('/')-1]
        #  puts "Path: #{path}"
        #  puts "Attributes: #{session.lstat!(file).attributes}"
        #  puts FileUtils.chown(session.lstat!(path).attributes[:uid], session.lstat!(path).attributes[:gid], tmp_dir + path)
        #  puts FileUtils.chmod(session.lstat!(path).attributes[:permissions], tmp_dir + path)
        #end

        FileUtils.chown(session.lstat!(file).attributes[:uid], session.lstat!(file).attributes[:gid], target_path) 
        FileUtils.chmod(session.lstat!(file).attributes[:permissions], target_path)
      end
    end

    tmp_module = Tempfile.new("module-#{node['id']}")
    tmp_module.close
    system("mksquashfs #{tmp_dir} #{tmp_module.path} -noappend")
    node_module_resource["#{node_module_category['name']}/#{node_module_identifier}"].post(:accept => :json,
                                                            :data => File.open(tmp_module),
                                                            :multipart => true,
                                                            :content_type => "application/octet-stream"
                                                            ) do |response, request, result, &block|
      case response.code
      when 200
        p "200 #{result} #{response}"
        response
      when 404
        p "404 Error: #{result}"
      else
        response.return!(request, result, &block)
      end
    end
    FileUtils.remove_entry_secure tmp_dir

    puts "Commit complete."
  end
end

def check_instances(node)
  puts "Checking instances for #{node['identifier']}"
end

def destroy_instances(node, node_instances, node_platform, count = 1)
  puts "Destroying #{count} instances for #{node['identifier']}..."
  node_resource = RestClient::Resource.new(APP_CONFIG['node_url'],
                                           node['identifier'],
                                           node['passphrase'])
  count.times do |n|
    node_instance = node_instances.reverse[n]
    unless count < node['instances'] && node_instance['primary'] == false
      begin
        aws_instance = @ec2.terminate_instances([node_instance['aws_instance']])
      rescue
      end
      node_resource['instance'].post(:accept => :json,
                                     :node_instance => node_instance,
                                     :operation => "destroy")
    else
    end
  end
end

def launch_instances(node, node_template, node_platform, count = 1)
  puts "Loading key for Node ID #{node['id']}..."
  keypair_name = "node-#{node['id']}"
  keys = @ec2.describe_key_pairs([keypair_name])
  node_resource = RestClient::Resource.new(APP_CONFIG['node_url'],
                                           node['identifier'],
                                           node['passphrase'])

  if !keys[0].nil? && node['key']
    key = keys[0]
  else
    @ec2.delete_key_pair(keypair_name)
    key = @ec2.create_key_pair(keypair_name)
    node_resource.post(:accept => :json,
                       :key => key[:aws_material],
                       :key_fingerprint => key[:aws_fingerprint])
  end

  user_data = <<END
#!/bin/sh
PARENT=#{node_platform['url']}
IDENTIFIER=#{node['identifier']}
PASSPHRASE=#{node['password']}
END

  puts "Launching #{count} instances for #{node['identifier']}..."
  count.times do
    begin
      aws_instance = @ec2.launch_instances(node_template['aws_image'], :kernel_id => node_template['aws_kernel'],
                                                                       :ramdisk_id => node_template['aws_ramdisk'],
                                                                       :aws_availability_zone => node_template['aws_availability_zone'],
                                                                       :instance_type => node_template['aws_instance_type'],
                                                                       :key_name => keypair_name,
                                                                       :user_data => user_data)
    rescue

    end
    node_resource['instance'].post(:accept => :json,
                                   :aws_instance => aws_instance,
                                   :operation => "create") if aws_instance
  end
end

$beetle.listen do
  puts "Started Powernode Manager."
  trap("INT") do
    $beetle.stop_listening
    puts "Stopped Powernode Server."
  end
end
