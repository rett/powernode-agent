#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'aws'
require 'json'
require 'logger'
require 'resque'
require 'resque-lock-timeout'
require 'restclient'
require 'net/ssh'
require 'net/sftp'
require 'tmpdir'

APP_CONFIG = YAML.load_file(File.join(File.dirname(__FILE__), "config.yml"))

Resque.redis = APP_CONFIG['redis_server']

$logger = Logger.new(File.join(File.dirname(__FILE__) + "/log/manager.log"), "daily")
$logger.level = Logger.const_get(APP_CONFIG['loglevel'].upcase)

class Manager
  extend Resque::Plugins::LockTimeout
  @lock_timeout = APP_CONFIG['timeout'] if APP_CONFIG['timeout']
  @queue = :manager

  def self.perform(message)
    @params = JSON.parse(message)
    @operation = @params['operation']

    begin
      @node_parent = APP_CONFIG['parent_url']
      @node_platform = @params['node_platform']
      @node_platform_resource = RestClient::Resource.new("#{@node_parent}/manage/platform/#{@node_platform}",
                                                        APP_CONFIG['identifier'],
                                                        APP_CONFIG['passphrase'])
      @node_response = JSON.parse(@node_platform_resource["nodes/#{@params['node']}"].get(accept: :json))
      @node = @node_response['node']
      @node_template = @node_response['node_template']
      @node_instances = @node_response['node_instances']
      @node_module_categories = @node_response['node_module_categories']
      @node_modules = @node_response['node_modules']
      @node_provider = @node_response['node_provider']
      @node_template = @node_response['node_template']
      @node_module_commit = @node_response['node_module_commit']
      @stamp = "[#{@operation}:#{@node['identifier']}]"
      self.send("node_#{@operation}") if self.respond_to?("node_#{@operation}")
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
  end

  def self.node_poll
    instance_variance = @node['instances'] - @node_instances.count
    $logger.info "#{@stamp} Poll started."
    @node_platform_resource["nodes/#{@node['identifier']}"].post(polling: true)
    @ec2 = Aws::Ec2.new(@node_provider['aws_access_key'],
                        @node_provider['aws_secret_key'],
                        { endpoint_url: !@node_provider['aws_url'].empty? ? @node_provider['aws_url'] : nil })
    if @node['enabled']
      node_check_instances
      if instance_variance > 0
        $logger.info "#{@stamp} Launching #{instance_variance} instances."
        node_launch_instances(instance_variance)
      elsif instance_variance < 0
        instance_variance = instance_variance.abs
        $logger.info "#{@stamp} Destroying #{instance_variance} instances."
        node_destroy_instances(instance_variance)
      end
      if !@node['node_module_commit'].nil?
        @node['node_module_commit'].each do |node_module_commit|
          node_module = @node_modules.find { |m| m['id'] == node_module_commit }
          node_commit_node_module(node_module)
        end
      end
      node_instance_exec
      node_trigger_update if @node['trigger_update']
    else
      if @node_instances.count > 0
        $logger.info "#{@stamp} Node disabled, destroying #{@node_instances.count} instances."
        node_destroy_instances(@node_instances.count)
      end
    end
    $logger.info "#{@stamp} Poll complete."
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

  def self.node_check_instances
    $logger.info "#{@stamp} Performing instance check."
    begin
      aws_instances = @ec2.describe_instances(@node_instances.map { |i| i['aws_instance'] })
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
    @node_instances.each do |node_instance|
      if node_instance['cloud']
        if (aws_instance = aws_instances.find { |i| i[:aws_instance_id] == node_instance['aws_instance'] })
          node_instance['error_count'] = 0
          node_instance['ip_private'] = aws_instance[:private_dns_name]
          node_instance['state'] = aws_instance[:aws_state]
        else
          if node_instance['error_count'] < APP_CONFIG['cloud_error_limit']
            node_instance['error_count'] += 1
          else
            @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(node_instance: node_instance, operation: "destroy")
          end
        end
      else
        # Todo: Check physical instance
      end
    end
    begin
      @node_platform_resource["nodes/#{@node['identifier']}/instances.json"].post(node_instances: @node_instances.to_json)
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
    $logger.info "#{@stamp} Instance check complete."
  end

  def self.node_commit_node_module(node_module)
    $logger.info "#{@stamp} Committing module #{node_module['identifier']}."
    node_instance = @node_instances.find { |i| i['primary'] }
    if node_instance && !node_module['spec'].empty?
      tmp_dir = Dir.mktmpdir
      FileUtils.chmod(0755, tmp_dir)
      Net::SFTP.start(node_instance['ip_private'], @node_template['admin_user'], key_data: @node['key'], paranoid: false) do |session|
        node_module['spec'].each_line do |file|
          file.chomp!
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
          rescue Exception => e
            $logger.error "#{@stamp} Exception: #{e} on file: #{file}"
          end
          begin
            FileUtils.chown(session.lstat!(file).attributes[:uid], session.lstat!(file).attributes[:gid], target_path)
            FileUtils.chmod(session.lstat!(file).attributes[:permissions], target_path)
          rescue Exception => e
            $logger.error "#{@stamp} Exception: #{e.message}"
          end
        end
      end
      tmp_module = Tempfile.new("module-#{@node['id']}")
      tmp_module.close
      system("mksquashfs #{tmp_dir} #{tmp_module.path} -noappend")
      @node_platform_resource["nodes/#{@node['identifier']}/modules/#{node_module['identifier']}.json"].post(
        accept: :json,
        data: File.open(tmp_module),
        multipart: true,
        content_type: "application/octet-stream")
      FileUtils.remove_entry_secure tmp_dir
      $logger.info "#{@stamp} Commit complete."
    elsif node_instance.nil?
      $logger.warn "#{@stamp} Commit aborted: No primary node instance found!"
    else
      $logger.warn "#{@stamp} Commit aborted: No module specification!"
    end
  end

  def self.node_destroy_instances(count = 1)
    $logger.info "#{@stamp} Destroying #{count} instances."
    count.times do |n|
      node_instance = @node_instances.reverse[n]
        begin
          @ec2.terminate_instances([node_instance['aws_instance']])
        rescue Exception => e
          $logger.error "#{@stamp} Exception: #{e.message}"
        end
        begin
          @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(node_instance: node_instance, operation: "destroy")
        rescue Exception => e
          $logger.error "#{@stamp} Exception: #{e.message}"
        end
    end
  end

  def self.node_instance_exec
    @node_instances.each do |node_instance|
      node_instance['execute'] ||= []
      node_instance['execute'].each do |command|
        $logger.error "#{@stamp} Executing \'#{command}\' on #{node_instance['aws_instance']}..."
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
    begin
      @node_platform_resource["nodes/#{@node['identifier']}/instances.json"].post(node_instances: @node_instances.to_json)
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
  end

  def self.node_launch_instances(count = 1)
    $logger.info "#{@stamp} Loading key."
    keypair_name = @node['identifier']
    begin
      keys = []
      keys = @ec2.describe_key_pairs([keypair_name])
    rescue Exception => e
      $logger.error "#{@stamp} Exception: #{e.message}"
    end
    if keys[0].try(:aws_fingerprint) == @node['key_fingerprint']
      key = keys[0]
    else
      begin
        @ec2.delete_key_pair(keypair_name)
      rescue Exception => e
        $logger.error "#{@stamp} Exception: #{e.message}"
      end
      begin
        key = @ec2.create_key_pair(keypair_name)
      rescue Exception => e
        $logger.error "#{@stamp} Exception: #{e.message}"
      end

      if key
        @node_platform_resource["nodes/#{@node['identifier']}"].post(accept: :json,
                                                                     aws_material: key[:aws_material],
                                                                     aws_fingerprint: key[:aws_fingerprint])
      end
    end

    user_data = <<-END
PARENT=\"#{@node_parent}\"
IDENTIFIER=\"#{@node['identifier']}\"
PASSPHRASE=\"#{@node['passphrase']}\"
PROVISIONAL="true"
    END

    count.times do
      begin
        aws_instance = @ec2.launch_instances(@node_provider['aws_image'],
                                             kernel_id: @node_provider['aws_kernel'],
                                             ramdisk_id: @node_provider['aws_ramdisk'],
                                             aws_availability_zone: @node_provider['aws_availability_zone'],
                                             instance_type: @node_template['aws_instance_type'],
                                             key_name: keypair_name,
                                             user_data: user_data)[0]
      rescue Exception => e
        $logger.error "#{@stamp} Exception: #{e.message}"
      end
      node_instance = {}
      node_instance['aws_instance'] = aws_instance[:aws_instance_id]
      node_instance['cloud'] = true
      node_instance['ip_private'] = aws_instance[:private_dns_name]
      node_instance['state'] = aws_instance[:aws_state]
      node_instance['started_at'] = aws_instance[:aws_launch_time]
      begin
        @node_platform_resource["nodes/#{@node['identifier']}/instance.json"].post(node_instance: node_instance)
      rescue Exception => e
        $logger.error "#{@stamp} Exception: #{e.message}"
      end
    end
  end
end
