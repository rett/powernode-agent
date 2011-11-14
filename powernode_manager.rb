require 'aws'
require 'rubygems'
require 'bundler/setup'
require 'restclient'
require 'beetle'
require 'json'
require 'net/ssh'
require 'net/scp'

Beetle.config do |config|
  config.logger.level = Logger::DEBUG
  config.servers = "192.168.1.2:5672"
  config.redis_server = "192.168.1.2:6379"
  config.redis_servers = "192.168.1.2:6379"
end

$beetle = Beetle::Client.new
$beetle.register_queue(:powernode)
$beetle.register_message(:powernode)

$beetle.register_handler(:powernode, :exceptions => 1, :delay => 0) do |message|
  puts "#{message.data}"
  params = JSON.parse(message.data)
  operation = params["operation"]

  fork { self.send(operation, params) } if self.respond_to?(operation)
end

def self.node_trigger_update(params)
  node = params['node']
  node_instances = params['node_instances']
  node_module_categories = params['node_module_categories']

  if node['enabled'] == true
    puts "Triggering update on #{node['identifier']}..."
    system("ssh-keygen -R #{node['public_address']} 2>/dev/null")
  
    node_instances.each do |node_instance|
      session = Net::SSH.start(node_instance['ip_public'], params['admin_user'], :key_data => node['key'])
      node_module_categories.each do |c|
        puts session.exec!("sudo ipn -uv #{c} all")
      end
    end
    puts "Trigger complete."
  end
end

def self.node_update_status(params)
  node = params['node']
  node_instances = params['node_instances']
  node_platform = params['node_platform']
  node_template = params['node_template']

  instance_count_difference = node['instances'] - node_instances.count

  puts "Instance count difference: #{instance_count_difference}"

  @ec2 = Aws::Ec2.new(node_platform['aws_access_key'],
                      node_platform['aws_secret_key'],
                      {:endpoint_url => node_platform['aws_url']})

  if node['enabled'] == true
    if instance_count_difference > 0
      puts "Not enough instances, launching #{instance_count_difference} instances..."
      launch_instances(node, node_template, instance_count_difference)
    elsif instance_count_difference < 0
      instance_count_difference *= -1
      puts "Too many instances, destroying #{instance_count_difference} instances..."
      destroy_instances(node, node_instances, instance_count_difference)
    else
      puts "Correct number of instances running."
    end
  else
    if node_instances.count > 0
      puts "Node disabled, destroying #{node_instances.count} instances..."
      destroy_instances(node, node_instances, node_instances.count)
    end
  end

  # Todo: Update node status.
  puts "Status update complete."
end

def self.node_module_commit(params)
  # Todo: Fetch files in module spec, package into module, upload to parent.

  node = params['node']
  node_module = params['node_module']
  node_module_category = params['node_module_category']

  puts "Commiting module #{node_module['identifier']} from node #{node['identifier']}..."

  node_module_resource_path = "#{node['parent']}/manage/modules"
  puts "Module resource path: #{node_module_resource_path}"
  node_module_resource = RestClient::Resource.new(node_module_resource_path, node['identifier'], node['passphrase'])



  node_module_resource["#{node_module_category['name']}/#{node_module['identifier']}"].post(:data => File.open('apache-1.mo'),
                                                            :multipart => true,
                                                            :content_type => "application/octet-stream",
                                                            :accept => :json) do |response, request, result, &block|
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

  puts "Commit complete."
end

def check_instances(node)
  puts "Checking instances for #{node['identifier']}"
end

def destroy_instances(node, node_instances, count = 1)
  puts "Destroying #{count} instances for #{node['identifier']}..."
  node_resource_path = "#{node['parent']}/manage/node"
  node_resource = RestClient::Resource.new(node_resource_path, node['identifier'], node['passphrase'])



  puts "Node instances: #{node_instances}"

  count.times do |n|
    node_instance = node_instances.reverse[n]['aws_instance']
    puts "Node Instance: #{node_instances}"

    unless count < node['instances'] && node_instance['primary'] == false
      @ec2.terminate_instances([node_instance])
      node_resource.post(:node_instance => node_instance, :destroy => true, :accept => :json)
    else

    end

  end
end

def launch_instances(node, node_template, count = 1)
  puts "Loading key for Node ID #{node['id']}..."
  keypair_name = "node-#{node['id']}"
  keys = @ec2.describe_key_pairs([keypair_name])
  puts "Keys: #{keys}"

  node_resource_path = "#{node['parent']}/manage/node"
  node_resource = RestClient::Resource.new(node_resource_path, node['identifier'], node['passphrase'])

  if !keys[0].nil?
    key = keys[0]
  else
    key = @ec2.create_key_pair(keypair_name)
    puts "Node resource path: #{node_resource_path}"
    node_resource.post(:key => key[:aws_material], :key_fingerprint => key[:aws_fingerprint]) do |response, request, result, &block|
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
  end

  user_data = <<END
#!/bin/sh
PARENT=#{node['parent']}
IDENTIFIER=#{node['identifier']}
PASSPHRASE=#{node['password']}
END

  puts "Launching #{count} instances for #{node['identifier']}..."
  count.times do
    begin
      node_instance = @ec2.launch_instances(node_template['aws_image'], :kernel_id => node_template['aws_kernel'],
                                                                        :ramdisk_id => node_template['aws_ramdisk'],
                                                                        :aws_availability_zone => node_template['aws_availability_zone'],
                                                                        :instance_type => node_template['aws_instance_type'],
                                                                        :key_name => keypair_name,
                                                                        :user_data => user_data)
    rescue

    end
    node_resource.post(:node_instance => node_instance) if node_instance
  end
end

$beetle.listen do
  puts "Started Powernode Manager."
  trap("INT") do
    $beetle.stop_listening
    puts "Stopped Powernode Server."
  end
end



