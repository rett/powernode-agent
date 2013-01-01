#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '../Gemfile')

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'fog'
require 'json'
require 'net/ssh'
require 'net/sftp'
require 'restclient'
require 'sidekiq'
require 'sidekiq-unique-jobs'
require 'tmpdir'
require 'powernode'

class Manager
  include Powernode
  include Sidekiq::Worker

  Powernode.logger_init(Powernode.config('manager_logfile'), Powernode.config('log_cycle'), Powernode.config('manager_loglevel'))

  Sidekiq.configure_server do |config|
    config.logger = Powernode.logger
    config.redis = { namespace: Powernode.config('redis_namespace'), url: Powernode.config('redis_server') }
  end

  sidekiq_options queue: Powernode.config('manager_queue'),
                  retry: Powernode.config('job_retries'),
                  unique: true,
                  unique_job_expiration: Powernode.config('manager_job_expiration')

  def perform(message)
    params = ActiveSupport::JSON.decode(message)
    @operation = params['operation']
    @node = Node.new(params['node'])
    @parent_resource = RestClient::Resource.new(Powernode.config('parent') + '/api/v1',
                                                Powernode.config('id'),
                                                Powernode.config('key'))
    begin
      node_response = JSON.parse(@parent_resource['node'][@node.id].get)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
      # exit 1
    end
    @node = Node.new(node_response)
    @stamp = "[#{@operation}:#{@node.id}]"
    send("do_#{@operation}") if respond_to?("do_#{@operation.to_s}")
  end

  protected

  def do_poll_instances
    logger.info "#{@stamp} Performing cloud instance check."
    instance_variance = @node.instance_count - @node.cloud_instances.count
    logger.info "#{@stamp} Instance variance: #{instance_variance}"
    begin
      @parent_resource['node']["#{@node.id}.json"].put(poll: true)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
      # exit 1
    end
    begin
      @ec2 = Fog::Compute.new(:provider => 'AWS',
                              :endpoint => @node.node_provider.aws_url,
                              :aws_access_key_id => @node.node_provider.aws_access_key,
                              :aws_secret_access_key => @node.node_provider.aws_secret_key)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
      # exit 1
    end
    if @ec2
      if @node.enabled
        if @node.cloud_instances.count > 0
          @node.cloud_instances.each do |node_instance|
            begin
              aws_instance = @ec2.servers.get(node_instance.aws_instance)
            rescue Exception => e
              logger.error "#{@stamp} Exception: #{e.message}"
              # exit 1
            end
            if aws_instance && aws_instance.flavor_id == @node.node_instance_type.name
              logger.info "#{@stamp} Updating instance: #{aws_instance.id}"
              node_instance.error_count = 0
              node_instance.ip_private = aws_instance.private_ip_address
              node_instance.ip_public = aws_instance.public_ip_address
              node_instance.state = aws_instance.state
              @parent_resource["node/#{@node.id}/instances.json"].post(node_instance: node_instance.to_json)
            elsif aws_instance && aws_instance.flavor_id != @node.node_instance_type.name
              logger.info "#{@stamp} Node instance type incorrect for instance: #{aws_instance.id}"
              destroy_cloud_instance(node_instance)
              launch_instances(1)
            elsif node_instance.error_count < Powernode.config('manager_cloud_error_limit')
              logger.info "#{@stamp} Incrementing error count for instance: #{node_instance.aws_instance}"
              node_instance.error_count += 1
              @parent_resource["node/#{@node.id}/instances.json"].post(node_instance: node_instance.to_json)
            else
              # Todo: Confirm before deregistering instance
              logger.info "#{@stamp} Deregistering instance: #{node_instance.aws_instance}"
              @parent_resource["node/#{@node.id}/instances.json"].delete(params: { node_instance: node_instance.to_json })
            end
          end
        end
        if instance_variance > 0
          logger.info "#{@stamp} Launching #{instance_variance} instances."
          launch_instances(instance_variance)
        elsif instance_variance < 0
          instance_variance = instance_variance.abs
          logger.info "#{@stamp} Destroying #{instance_variance} instances."
          destroy_cloud_instances(@node.cloud_instances, instance_variance)
        end
        if @node_module_commit.is_a?(Array)
          @node_module_commit.each do |node_module_commit|
            node_module = @node_modules.find { |m| m.id == node_module_commit }
            commit_node_module(node_module)
          end
        end
      elsif @node.cloud_instances.count > 0
        destroy_cloud_instances(@node.cloud_instances, @node.cloud_instances.count)
      end
    end
    logger.info "#{@stamp} Cloud instance check complete."
  end

  def do_poll_physical_instances
    logger.info "#{@stamp} Performing physical instance check."
    @node.physical_instances.each do |node_instance|
      logger.info "#{@stamp} Checking physical instance #{node_instance.id}"
    end
    logger.info "#{@stamp} Physical instance check complete."
  end

  def do_trigger_update
    if @node.enabled
      @parent_resource["node/#{@node.id}"].post(trigger_update: true)
      @node.node_instances.each do |node_instance|
        logger.info "#{@stamp} Triggering update on instance: #{node_instance.aws_instance}."
        @parent_resource["node/#{@node.id}/instance.json"].post(node_instance: node_instance.to_json)
        begin
          session = Net::SSH.start(node_instance.ip_private,
                                   @node.node_template.admin_user,
                                   key_data: @node.key,
                                   paranoid: false)
        rescue Exception => e
          logger.error "#{@stamp} Exception: #{e.message}"
          # exit 1
        end
        if session
          begin
            session.exec!("sudo ipn -auv all")
          rescue Exception => e
            logger.error "#{@stamp} Exception: #{e.message}"
            # exit 1
          end
        end
      end
    end
  end

  private

  def commit_node_module(node_module)
    logger.info "#{@stamp} Committing module #{node_module.id}."
    node_instance = JSON.parse(@parent_resource["node/#{@node.id}/instances"].get(params: { criteria: :primary }))
    if node_instance && !node_module.effective_spec.empty?
      tmp_dir = Dir.mktmpdir
      FileUtils.chmod(0755, tmp_dir)
      Net::SFTP.start(node_instance.ip_private, @node.node_template.admin_user, key_data: @node.key, paranoid: false) do |session|
        node_module.effective_spec.each do |file|
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
            logger.error "#{@stamp} Exception: #{e} on file: #{file}"
            # exit 1
          end
        end
      end
      tmp_module = Tempfile.new("module-#{@node.id}")
      tmp_module.close
      system("mksquashfs #{tmp_dir} #{tmp_module.path} -noappend")
      if tmp_module.size > 0
        @parent_resource["node/#{@node.id}/modules/#{node_module.id}.json"].post(
          data: File.open(tmp_module),
          multipart: true,
          content_type: "application/octet-stream")
        FileUtils.remove_entry_secure tmp_dir
        logger.info "#{@stamp} Commit complete."
      else
        logger.info "#{@stamp} Commit # exit 1ed."
      end
    elsif node_instance.nil?
      logger.info "#{@stamp} Commit # exit 1ed: No primary instance found!"
    else
      logger.info "#{@stamp} Commit # exit 1ed: No module specification!"
    end
  end

  def destroy_cloud_instances(cloud_instances, count)
    count.times do |n|
      node_instance = cloud_instances.reverse[n]
      destroy_cloud_instance(node_instance)
    end
  end

  def destroy_cloud_instance(node_instance)
    logger.info "#{@stamp} Destroying instance: #{node_instance.aws_instance}"
    begin
      if @ec2.servers.destroy(node_instance.aws_instance)
        @parent_resource["node/#{@node.id}/instances.json"].delete(params: { node_instance: node_instance.to_json })
      end
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
      # exit 1
    end
  end

  def instance_exec(node_instances)
    node_instances.each do |node_instance|
      logger.info "#{@stamp} Executing commands on instance: #{node_instance.name}"
      if node_instance.execute.is_a?(Array)
        node_instance.execute.each do |command|
          logger.info "#{@stamp} Executing \'#{command}\' on #{node_instance.aws_instance}..."
          node_instance.execute.delete(command)
          begin
            session = Net::SSH.start(node_instance.ip_private,
                                     @node_template.admin_user,
                                     key_data: @node.key,
                                     paranoid: false)
          rescue Exception => e
            logger.error "#{@stamp} Exception: #{e.message}"
            # exit 1
          end
          if session
            begin
              session.exec!("sudo #{command}")
            rescue Exception => e
              logger.error "#{@stamp} Exception: #{e.message}"
              # exit 1
            end
          end
        end
      end
    end
    begin
      @parent_resource["node/#{@node.id}/instances.json"].post(node_instances: node_instances.to_json)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
      # exit 1
    end
  end

  def launch_instances(count = 1)
    logger.info "#{@stamp} Loading key."
    keypair_name = @node.id
    keys = []
    begin
      logger.info "#{@stamp} Attempting to retrieve keypairs..."
      keys = @ec2.key_pairs.all
      key = keys.select { |k| k.name == keypair_name }.first
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
      # exit 1
    end
    if key && key.fingerprint == @node.key_fingerprint
      logger.info "#{@stamp} Found valid key: #{keypair_name}"
    else
      begin
        logger.info "#{@stamp} Deleting key: #{keypair_name}"
        @ec2.delete_key_pair(keypair_name)
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
        # exit 1
      end
      begin
        logger.info "#{@stamp} Creating key: #{keypair_name}"
        key = @ec2.key_pairs.create(name: keypair_name)
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
        # exit 1
      end
      logger.info "#{@stamp} Using key: #{keypair_name}"
      if key && key.private_key
        @parent_resource["node/#{@node.id}"].post(key: key.private_key, key_fingerprint: key.fingerprint)
      end
    end

    user_data = <<-END
ID=\"#{@node.id}\"
KEY=\"#{@node.key}\"
PARENT=\"#{Powernode.config('parent')}\"
PROVISIONAL=\"true\"
    END

    count.times do
      instance_options = {}
      instance_options[:availability_zone] = @node.node_provider.aws_availability_zone if @node.node_provider.aws_availability_zone
      instance_options[:image_id] = @node.node_provider.aws_image if !@node.node_provider.aws_image.empty?
      instance_options[:ramdisk_id] = @node.node_provider.aws_ramdisk if !@node.node_provider.aws_ramdisk.empty?
      instance_options[:flavor_id] = @node.node_instance_type.name
      instance_options[:key_name] = key.name
      instance_options[:user_data] = user_data
      begin
        if (aws_instance = @ec2.servers.create(instance_options))
          logger.info "#{@stamp} Created new instance: #{aws_instance.id}"
          node_instance = NodeInstance.new({ name: aws_instance.id,
                                             aws_instance: aws_instance.id,
                                             cloud: true,
                                             ip_private: aws_instance.private_ip_address,
                                             ip_public: aws_instance.public_ip_address,
                                             state: aws_instance.state,
                                             started_at: aws_instance.created_at })
          unless @parent_resource["node/#{@node.id}/instances.json"].post(node_instance: node_instance.to_json)
            @ec2.servers.destroy(aws_instance.id)
          end
        end
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
        # exit 1
      end
    end
  end
end
