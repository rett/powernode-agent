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

#RestClient.log = 'stdout'

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

$node_platform_resource = RestClient::Resource.new(APP_CONFIG['platform_url'],
                                                   APP_CONFIG['platform_identifier'],
                                                   APP_CONFIG['platform_passphrase'])

def self.node_trigger_update(params)
  node_response = JSON.parse($node_platform_resource["nodes/#{params['node']['identifier']}"].get(:accept => :json))

  node = node_response['node']
  node_instances = node_response['node_instances']
  node_module_categories = node_response['node_module_categories']
  node_template = node_response['node_template']

  if node['enabled'] == true
    $node_platform_resource["nodes/#{node['identifier']}"].post(:trigger_update => true)
    node_instances.each do |node_instance|
      if node_instance['last_update'].nil? || Time.parse(node_instance['last_update']) < APP_CONFIG['poll_interval'].seconds.ago
        puts "Triggering update on instance: #{node_instance['aws_instance']}..."
        node_instance['last_update'] = Time.now
        $node_platform_resource["nodes/#{node['identifier']}/instance.json"].post(:node_instance => node_instance)
        #begin
          session = Net::SSH.start(node_instance['ip_private'],
                                   node_template['admin_user'],
                                   :key_data => node['key'],
                                   :paranoid => false)
        #rescue
        #end
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
  node_response = JSON.parse($node_platform_resource["nodes/#{params['node']['identifier']}"].get(:accept => :json))

  node = node_response['node']
  node_instances = node_response['node_instances']
  node_platform = node_response['node_platform']
  node_template = node_response['node_template']
  instance_variance = node['instances'] - node_instances.count

  @ec2 = Aws::Ec2.new(node_platform['aws_access_key'],
                      node_platform['aws_secret_key'],
                      {:endpoint_url => node_platform['aws_url']})

  if node['enabled'] == true
    check_instances(node, node_instances)
    if instance_variance > 0
      puts "Launching #{instance_variance} instances..."
      launch_instances(node, node_template, node_platform, instance_variance)
    elsif instance_variance < 0
      instance_variance *= -1
      puts "Destroying #{instance_variance} instances..."
      destroy_instances(node, node_instances, instance_variance)
    else
      puts "Correct number of instances running."
    end
  else
    if node_instances.count > 0
      puts "Node disabled, destroying #{node_instances.count} instances..."
      destroy_instances(node, node_instances, node_instances.count)
    end
  end
  puts "Status update complete."
end

def self.node_module_commit(params)
  node = params['node']
  node_module = params['node_module']
  node_template = params['node_template']
  puts node_instance = params['node_instance']
  #node_module_category = params['node_module_category']
  #node_module_identifier = params['node_module_identifier']
  #node_module_spec = params['node_module_spec']
  #node_platform = params['node_platform']

  #if node_instance['state'] == "active"
  puts "Committing module #{node_module['name']} from node #{node['identifier']}..."

  tmp_dir = Dir.mktmpdir
  FileUtils.chmod(0755, tmp_dir)

  puts "Spec: #{node_module['spec']}"

  Net::SFTP.start(node_instance['ip_private'], node_template['admin_user'], :key_data => node['key'], :paranoid => false) do |session|
    node_module['spec'].each_line do |file|
      file.chomp!
      target_path = tmp_dir + file
      puts "Target File: #{file}"
      #begin
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
      #rescue
      #end

      #path = file
      #while path.rindex('/') > 0 do
      #  path = path[0..path.rindex('/')-1]
      #  puts "Path: #{path}"
      #  puts "Attributes: #{session.lstat!(file).attributes}"
      #  puts FileUtils.chown(session.lstat!(path).attributes[:uid], session.lstat!(path).attributes[:gid], tmp_dir + path)
      #  puts FileUtils.chmod(session.lstat!(path).attributes[:permissions], tmp_dir + path)

      #begin
        FileUtils.chown(session.lstat!(file).attributes[:uid], session.lstat!(file).attributes[:gid], target_path)
        FileUtils.chmod(session.lstat!(file).attributes[:permissions], target_path)
      #rescue
      #end
    end
  end

  tmp_module = Tempfile.new("module-#{node['id']}")
  tmp_module.close
  system("mksquashfs #{tmp_dir} #{tmp_module.path} -noappend")
  $node_platform_resource["nodes/#{node['identifier']}/modules/#{node_module['identifier']}.json"].post(
    :accept => :json,
    :data => File.open(tmp_module),
    :multipart => true,
    :content_type => "application/octet-stream")

  FileUtils.remove_entry_secure tmp_dir

  puts "Commit complete."
end

def check_instances(node, node_instances)
  puts "Checking instances for #{node['identifier']}..."

  #begin
    aws_instances = @ec2.describe_instances(node_instances.map {|i| i['aws_instance']})
  #rescue
  #end

  node_instances.each do |node_instance|
    if aws_instance = aws_instances.find {|i| i[:aws_instance_id] == node_instance['aws_instance']}
      node_instance.delete('id')
      node_instance.delete('node_id')
      node_instance['error_count'] = 0
      node_instance['ip_private'] = aws_instance[:private_dns_name]
      node_instance['state'] = aws_instance[:aws_state]
    else
      if node_instance['error_count'] < 3
        node_instance['error_count'] += 1
      else
        $node_platform_resource["nodes/#{node['identifier']}/instance.json"].post(:node_instance => node_instance, :operation => 'destroy')
      end
    end
  end

  #begin
    $node_platform_resource["nodes/#{node['identifier']}/instances.json"].post(:node_instances => node_instances.to_json)
  #rescue
  #end

end

def destroy_instances(node, node_instances, count = 1)
  puts "Destroying #{count} instances for #{node['identifier']}..."

  count.times do |n|
    node_instance = node_instances.reverse[n]
      #begin
        @ec2.terminate_instances([node_instance['aws_instance']])
      #rescue
      #end
      #begin
        $node_platform_resource["nodes/#{node['identifier']}/instance.json"].post(:node_instance => node_instance, :operation => 'destroy')
      #rescue
      #end
  end
end

def launch_instances(node, node_template, node_platform, count = 1)
  puts "Loading key for Node ID #{node['id']}..."
  keypair_name = "node-#{node['id']}"
  keys = @ec2.describe_key_pairs([keypair_name])

  if !keys[0].nil? && node['key']
    key = keys[0]
  else
    @ec2.delete_key_pair(keypair_name)
    key = ec2.create_key_pair(keypair_name)
    $node_platform_resource['.json'].post(key)
  end

  user_data = <<END
#!/bin/sh
PARENT=#{node_platform['url']}
IDENTIFIER=#{node['identifier']}
PASSPHRASE=#{node['passphrase']}
END

  puts "Launching #{count} instances for #{node['identifier']}..."

  count.times do
    #begin
      aws_instance = @ec2.launch_instances(node_template['aws_image'],
                                           :kernel_id => node_template['aws_kernel'],
                                           :ramdisk_id => node_template['aws_ramdisk'],
                                           :aws_availability_zone => node_template['aws_availability_zone'],
                                           :instance_type => node_template['aws_instance_type'],
                                           :key_name => keypair_name,
                                           :user_data => user_data)[0]
    #rescue
    #end

      node_instance = Hash.new
      node_instance['aws_instance'] = aws_instance[:aws_instance_id]
      node_instance['ip_private'] = aws_instance[:private_dns_name]
      node_instance['state'] = aws_instance[:aws_state]
      node_instance['start_time'] = aws_instance[:aws_launch_time]

    #begin
      $node_platform_resource["nodes/#{node['identifier']}/instance.json"].post(:node_instance => node_instance)
    #rescue
    #end
  end

end

$beetle.listen do
  puts "Started Powernode Manager."
  trap("INT") do
    $beetle.stop_listening
    puts "Stopped Powernode Server."
  end
end
