#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)

ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), 'Gemfile')

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'fog'
require 'json'
require 'logger'
require 'resque'
require 'resque-lock-timeout'
require 'restclient'
require 'net/ssh'
require 'net/sftp'
require 'tmpdir'

APP_CONFIG = YAML.load_file(File.join(File.dirname(__FILE__), 'config.yml'))

Resque.redis = APP_CONFIG['redis_server']

$logger = Logger.new(File.join(File.dirname(__FILE__) + '/log/manager.log'), 'daily')
$logger.level = Logger.const_get(APP_CONFIG['loglevel'].upcase)

class Manager
  extend Resque::Plugins::LockTimeout
  @lock_timeout = APP_CONFIG['timeout'] if APP_CONFIG['timeout']
  @queue = :manager

  def self.perform(message)
    @params = JSON.parse(message)
    @operation = @params['operation']

    begin
      @node_platform = @params['node_platform']
      @node_platform_resource = RestClient::Resource.new(APP_CONFIG['parent_url'] + '/manage/platform/' + @node_platform,
                                                         APP_CONFIG['identifier'],
                                                         APP_CONFIG['passphrase'])
      @node_response = JSON.parse(@node_platform_resource["nodes/#{@params['node']}.json"].get(accept: :json))
      @node = @node_response['node']
      @node_instances = @node_response['node_instances']
      @node_modules = @node_response['node_modules']
      @node_instance_type = @node_response['node_instance_type']
      @node_module_categories = @node_response['node_module_categories']
      @node_provider = @node_response['node_provider']
      @node_template = @node_response['node_template']
      @node_module_commit = @node_response['node_module_commit']
      @stamp = "[#{@operation}:#{@node['identifier']}]"
      self.send("node_#{@operation}") if self.respond_to?("node_#{@operation}")
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
  end

  def self.node_poll_cloud_instances
    $logger.info "#{@stamp} Performing cloud instance check."
    cloud_instances = JSON.parse(@node_platform_resource["nodes/#{@node['identifier']}/instances"].get(accept: :json,
                                                                                                       params: { criteria: :cloud }))
    instance_variance = @node['cloud_instances'] - cloud_instances.count
    $logger.info "#{@stamp} Instance variance: #{instance_variance}"
    @node_platform_resource["nodes/#{@node['identifier']}.json"].post(poll: true)
    begin
      @ec2 = Fog::Compute.new(:provider => 'AWS',
                              :endpoint => @node_provider.try(:[], 'aws_url'),
                              :aws_access_key_id => @node_provider['aws_access_key'],
                              :aws_secret_access_key => @node_provider['aws_secret_key'])
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
    if @node['enabled']
      if cloud_instances.count > 0
        cloud_instances.each do |node_instance|
          begin
            aws_instance = @ec2.servers.get(node_instance['aws_instance'])
          rescue Exception => e
            $logger.error "#{@stamp} Exception: #{e.message}"
          end
          if aws_instance && aws_instance.flavor_id == @node_instance_type['name']
            $logger.debug "#{@stamp} Detected running instance: #{aws_instance.id}"
            node_instance['error_count'] = 0
            node_instance['ip_private'] = aws_instance.private_ip_address
            node_instance['ip_public'] = aws_instance.public_ip_address
            node_instance['state'] = aws_instance.state
          elsif aws_instance && aws_instance.flavor_id != @node_instance_type['name']
            $logger.debug "#{@stamp} Node instance type incorrect for instance: #{aws_instance.id}"
            node_destroy_cloud_instance(node_instance)
            node_launch_instances(1)
          elsif node_instance['error_count'] < APP_CONFIG['cloud_error_limit']
            $logger.debug "#{@stamp} Incrementing error count for instance: #{node_instance['aws_instance']}"
            node_instance['error_count'] += 1
          else
            $logger.debug "#{@stamp} Deregistering instance: #{node_instance['aws_instance']}"
            # Todo: Confirm before deregistering instance
            @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(node_instance: node_instance, operation: 'destroy')
          end
        end
        begin
          @node_platform_resource["nodes/#{@node['identifier']}/instances.json"].post(node_instances: cloud_instances.to_json)
        rescue Exception => e
          $logger.error "#{@stamp} Exception: #{e.message}"
        end
      end
      if instance_variance > 0
        $logger.info "#{@stamp} Launching #{instance_variance} instances."
        node_launch_instances(instance_variance)
      elsif instance_variance < 0
        instance_variance = instance_variance.abs
        $logger.info "#{@stamp} Destroying #{instance_variance} instances."
        node_destroy_cloud_instances(cloud_instances, instance_variance)
      end
      if @node['node_module_commit'].is_a?(Array)
        @node['node_module_commit'].each do |node_module_commit|
          node_module = @node_modules.find { |m| m['identifier'] == node_module_commit }
          node_commit_node_module(node_module)
        end
      end
    elsif cloud_instances.count > 0
      node_destroy_cloud_instances(cloud_instances, cloud_instances.count)
    end
    $logger.info "#{@stamp} Cloud instance check complete."
  end

  def self.node_poll_physical_instances
    $logger.info "#{@stamp} Performing physical instance check."
    physical_instances = @node_instances.select { |i| i['cloud'] == false }
    physical_instances.each do |node_instance|
      $logger.info "#{@stamp} Checking physical instance #{node_instance['identifier']}"
    end
    $logger.info "#{@stamp} Physical instance check complete."
  end

  def self.node_trigger_update
    if @node['enabled'] == true
      @node_platform_resource["nodes/#{@node['identifier']}"].post(trigger_update: true)
      @node_instances.each do |node_instance|
        $logger.info "#{@stamp} Triggering update on instance: #{node_instance['aws_instance']}."
        @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(node_instance: node_instance)
        begin
          session = Net::SSH.start(node_instance['ip_private'],
                                   @node_template['admin_user'],
                                   key_data: @node['key'],
                                   paranoid: false)
        rescue Exception => e
          $logger.error "#{@stamp} Exception: #{e.message}"
        end
        if session
          @node_module_categories.each do |c|
            begin
              session.exec!("sudo ipn -auv #{c} all")
            rescue Exception => e
              $logger.error "#{@stamp} Exception: #{e.message}"
            end
          end
        end
      end
    end
  end

  def self.node_commit_node_module(node_module)
    $logger.info "#{@stamp} Committing module #{node_module['identifier']}."
    node_instance = JSON.parse(@node_platform_resource["nodes/#{@node['identifier']}/instances"].get(accept: :json,
                                                                                                     params: { criteria: :primary }))
    if node_instance && !node_module['effective_spec'].empty?
      tmp_dir = Dir.mktmpdir
      FileUtils.chmod(0755, tmp_dir)
      Net::SFTP.start(node_instance['ip_private'], @node_template['admin_user'], key_data: @node['key'], paranoid: false) do |session|
        node_module['effective_spec'].each do |file|
          target_path = tmp_dir + file
          target_path.gsub!(/\/+/, '/')
          file.gsub!(/\/+/, '/')
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
            FileUtils.chown(session.lstat!(file).attributes[:uid], session.lstat!(file).attributes[:gid], target_path)
            FileUtils.chmod(session.lstat!(file).attributes[:permissions], target_path)
          rescue Exception => e
            $logger.error "#{@stamp} Exception: #{e} on file: #{file}"
          end
        end
      end
      tmp_module = Tempfile.new("module-#{@node['identifier']}")
      tmp_module.close
      system("mksquashfs #{tmp_dir} #{tmp_module.path} -noappend")
      if tmp_module.size > 0
        @node_platform_resource["nodes/#{@node['identifier']}/modules/#{node_module['identifier']}.json"].post(
          accept: :json,
          data: File.open(tmp_module),
          multipart: true,
          content_type: "application/octet-stream")
        FileUtils.remove_entry_secure tmp_dir
        $logger.info "#{@stamp} Commit complete."
      else
        $logger.info "#{@stamp} Commit aborted."
      end
    elsif node_instance.nil?
      $logger.warn "#{@stamp} Commit aborted: No primary instance found!"
    else
      $logger.warn "#{@stamp} Commit aborted: No module specification!"
    end
  end

  def self.node_destroy_cloud_instances(cloud_instances, count = 1)
    count.times do |n|
      node_instance = cloud_instances.reverse[n]
      node_destroy_cloud_instance(node_instance)
    end
  end

  def self.node_destroy_cloud_instance(node_instance)
    $logger.info "#{@stamp} Attempting to destroy instance: #{node_instance['aws_instance']}"
    begin
      if @ec2.servers.destroy(node_instance['aws_instance'])
        @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(node_instance: node_instance, operation: "destroy")
      end
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
  end

  def self.node_instance_exec(node_instances)
    node_instances.each do |node_instance|
      $logger.info "#{@stamp} Executing commands on instance: #{node_instance['name']}"
      if node_instance['execute'].is_a?(Array)
        node_instance['execute'].each do |command|
          $logger.info "#{@stamp} Executing \'#{command}\' on #{node_instance['aws_instance']}..."
          node_instance['execute'].delete(command)
          begin
            session = Net::SSH.start(node_instance['ip_private'],
                                     @node_template['admin_user'],
                                     key_data: @node['key'],
                                     paranoid: false)
          rescue Exception => e
            $logger.error "#{@stamp} Exception: #{e.message}"
          end
          if session
            begin
              session.exec!("sudo #{command}")
            rescue Exception => e
              $logger.error "#{@stamp} Exception: #{e.message}"
            end
          end
        end
      end
    end
    begin
      @node_platform_resource["nodes/#{@node['identifier']}/instances.json"].post(node_instances: node_instances.to_json)
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
  end

  def self.node_launch_instances(count = 1)
    $logger.info "#{@stamp} Loading key."
    keypair_name = @node['identifier']
    keys = []
    begin
      $logger.debug "#{@stamp} Attempting to retrieve keypairs..."
      keys = @ec2.key_pairs.all
      key = keys.select { |k| k.name == keypair_name }.first
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
    if key && key.fingerprint == @node['key_fingerprint']
      $logger.debug "#{@stamp} Found valid key: #{keypair_name}"
    else
      begin
        $logger.debug "#{@stamp} Deleting key: #{keypair_name}"
        @ec2.delete_key_pair(keypair_name)
      rescue Exception => e
        $logger.error "#{@stamp} Exception: #{e.message}"
      end
      begin
        $logger.debug "#{@stamp} Creating key: #{keypair_name}"
        key = @ec2.key_pairs.create(name: keypair_name)
      rescue Exception => e
        $logger.error "#{@stamp} Exception: #{e.message}"
      end
      $logger.debug "#{@stamp} Using key: #{keypair_name}"
      if key && key.private_key
        @node_platform_resource["nodes/#{@node['identifier']}"].post(accept: :json,
                                                                     key: key.private_key,
                                                                     key_fingerprint: key.fingerprint)
      end
    end

    user_data = <<-END
PARENT=\"#{APP_CONFIG['parent_url']}\"
IDENTIFIER=\"#{@node['identifier']}\"
PASSPHRASE=\"#{@node['passphrase']}\"
PROVISIONAL=\"true\"
    END

    count.times do
        instance_options = {}
        instance_options[:availability_zone] = @node_provider['aws_availability_zone'] if @node_provider['aws_availability_zone']
        instance_options[:image_id] = @node_provider['aws_image'] if !@node_provider['aws_image'].empty?
        instance_options[:ramdisk_id] = @node_provider['aws_ramdisk'] if !@node_provider['aws_ramdisk'].empty?
        instance_options[:flavor_id] = @node_instance_type['name']
        instance_options[:key_name] = key.name
        instance_options[:user_data] = user_data
      begin
        if (aws_instance = @ec2.servers.create(instance_options))
          $logger.debug "#{@stamp} Created new instance: #{aws_instance.id}"
          node_instance = {}
          node_instance['name'] = aws_instance.id
          node_instance['aws_instance'] = aws_instance.id
          node_instance['cloud'] = true
          node_instance['ip_private'] = aws_instance.private_ip_address
          node_instance['ip_public'] = aws_instance.ip_address
          node_instance['state'] = aws_instance.state
          node_instance['started_at'] = aws_instance.created_at
          unless @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(node_instance: node_instance)
            @ec2.servers.destroy(aws_instance.id)
          end
        end
      rescue Exception => e
        $logger.error "#{@stamp} Exception: #{e.message}"
      end
    end
  end
end
