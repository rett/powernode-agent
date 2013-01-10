#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'fog'
require 'json'
require 'net/ssh'
require 'net/sftp'
require 'openssl'
require 'restclient'
require 'sidekiq'
require 'sidekiq-unique-jobs'
require 'tmpdir'
require 'powernode'
require 'powernode/models'

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
    @parent_resource = RestClient::Resource.new(Powernode.config('parent_url') + '/api/v1',
                                                Powernode.config('id'),
                                                Powernode.config('key'))
    begin
      @node = Node.new(JSON.parse(@parent_resource["node/#{@node.id}.json"].get))
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
    if @node
      @stamp = "[#{@operation}:#{@node.id}]"
      send("do_#{@operation}") if respond_to?("do_#{@operation.to_s}")
    end
  end

  protected

  def do_poll_instances
    logger.info "#{@stamp} Performing cloud instance check."
    logger.info "#{@stamp} Instance variance: #{@node.instance_variance}"
    begin
      @parent_resource['node']["#{@node.id}.json"].post(poll: true)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
    do_trigger_update if @node.trigger_update && Time.parse(@node.trigger_update) < Time.now



    begin
      @ec2 = Fog::Compute.new(:provider => 'AWS',
                              :endpoint => @node.node_provider.aws_url,
                              :aws_access_key_id => @node.node_provider.aws_access_key,
                              :aws_secret_access_key => @node.node_provider.aws_secret_key)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
    if @ec2
      if @node.enabled
        if @node.cloud_instances.count > 0
          @node.cloud_instances.each do |node_instance|
            begin
              aws_instance = @ec2.servers.get(node_instance.aws_instance)
              aws_available = true
            rescue Exception => e
              logger.error "#{@stamp} Exception: #{e.message}"
            end
            if aws_available
              if aws_instance && aws_instance.flavor_id == @node.node_instance_type.name
                logger.info "#{@stamp} Executing commands on #{aws_instance.id}"
                instance_exec(node_instance)
                logger.info "#{@stamp} Updating instance: #{aws_instance.id}"
                node_instance.ip_private = aws_instance.private_ip_address
                node_instance.ip_public = aws_instance.public_ip_address
                node_instance.state = aws_instance.state
                @parent_resource["node/#{@node.id}/instance/#{node_instance.id}.json"].post(node_instance: node_instance.to_json)
              elsif aws_instance && aws_instance.flavor_id != @node.node_instance_type.name
                logger.info "#{@stamp} Node instance type incorrect for instance: #{aws_instance.id}"
                destroy_cloud_instance(node_instance)
                launch_instances(1)
              else
                logger.info "#{@stamp} Deregistering invalid instance: #{node_instance.aws_instance}"
                @parent_resource["node/#{@node.id}/instance/#{node_instance.id}.json"].delete
                @node.node_instances.delete(node_instance)
              end
            end
          end
        end
        if @node.instance_variance > 0
          logger.info "#{@stamp} Launching #{@node.instance_variance} instances."
          launch_instances(@node.instance_variance)
        elsif @node.instance_variance < 0
          logger.info "#{@stamp} Destroying #{@node.instance_variance} instances."
          destroy_cloud_instances(@node.cloud_instances, @node.instance_variance.abs)
        end
        if @node.node_module_commit.is_a?(Array)
          @node.node_module_commit.each do |node_module_commit|
            node_module = NodeModule.new(JSON.parse(@parent_resource["node/#{@node.id}/module/#{node_module_commit}.json"].get))
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
        logger.info "#{@stamp} Triggering update on instance: #{node_instance.aws_instance}.\n\n"
        @parent_resource["node/#{@node.id}/instance.json"].post(node_instance: node_instance.to_json)
        begin
          session = Net::SSH.start(node_instance.ip_private,
                                   @node.node_template.admin_user,
                                   key_data: @node.ssh_key,
                                   paranoid: false)
        rescue Exception => e
          logger.error "#{@stamp} Exception: #{e.message}"
        end
        if session
          begin
            session.exec!("sudo ipn -auv all")
          rescue Exception => e
            logger.error "#{@stamp} Exception: #{e.message}"
          end
        end
      end
    end
  end

  private

  def commit_node_module(node_module)
    logger.info "#{@stamp} Committing module #{node_module.id}."
    if @node.primary_instance && !node_module.effective_spec.empty?
      tmp_dir = Dir.mktmpdir
      FileUtils.chmod(0755, tmp_dir)
      begin
        tmp_spec = Tempfile.new("spec-#{@node.id}-#{node_module.id}")
        File.open(tmp_spec, 'w') do |f|
          node_module.effective_spec.each do |file|
            f.write(file + "\n")
          end
        end
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
        FileUtils.remove_entry_secure(tmp_dir)
      end
      begin
        system("sudo rsync -a -e \"ssh -q -p #{Powernode.config('ssh_port')} -o StrictHostKeyChecking=no -i #{@node.ssh_key_file}\" --files-from=#{tmp_spec.path} #{@node.admin_user}@#{@node.primary_instance.ip_private}:/ #{tmp_dir}/")
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
      if File.directory?(tmp_dir)
        tmp_module = Tempfile.new("module-#{@node.id}-#{node_module.id}")
        tmp_module.close
        begin
          system("sudo mksquashfs #{tmp_dir} #{tmp_module.path} -comp #{Powernode.config('module_compression')} -noappend -no-progress > /dev/null")
        rescue Exception => e
          logger.error "#{@stamp} Exception: #{e.message}"
        end
        if tmp_module.size > 0
          begin
            new_node_module = NodeModule.new(JSON.parse(@parent_resource["node/#{@node.id}/module/#{node_module.id}.json"].post(
              data: File.open(tmp_module),
              multipart: true,
              content_type: 'application/octet-stream',
              accept: :json)))
          rescue Exception => e
            logger.error "#{@stamp} Exception: #{e.message}"
          end
          FileUtils.remove_entry_secure(tmp_dir, force: true)
          FileUtils.remove_entry_secure(tmp_module, force: true)
          logger.info "#{@stamp} Commit complete for node module #{new_node_module.data_file_name}."
        else
          logger.info "#{@stamp} Commit aborted."
        end
      end
    elsif @node.primary_instance.nil?
      logger.info "#{@stamp} Commit aborted: No primary instance found!"
    else
      logger.info "#{@stamp} Commit aborted: No module specification!"
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
        @parent_resource["node/#{@node.id}/instance/#{node_instance.id}.json"].delete
      end
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
  end

  def instance_exec(node_instance)
    if node_instance.execute.is_a?(Array)
      node_instance.execute.each do |command|
        logger.info "#{@stamp} Executing (#{command}) on #{node_instance.aws_instance}..."
        node_instance.execute.delete(command)
        begin
          session = Net::SSH.start(node_instance.ip_private,
                                   @node.admin_user,
                                   key_data: @node.ssh_key,
                                   paranoid: false)
        rescue Exception => e
          logger.error "#{@stamp} Exception: #{e.message}"
        end
        if session
          begin
            session.exec!("sudo #{command}")
          rescue Exception => e
            logger.error "#{@stamp} Exception: #{e.message}"
          end
        end
      end
    end
    begin
      @parent_resource["node/#{@node.id}/instance.json"].post(node_instance: node_instance.to_json)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
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
    end
    if key && key.fingerprint == @node.ssh_key_fingerprint
      logger.info "#{@stamp} Found valid key: #{keypair_name}"
    else
      begin
        logger.info "#{@stamp} Deleting key: #{keypair_name}"
        @ec2.delete_key_pair(keypair_name)
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
      begin
        logger.info "#{@stamp} Creating key: #{keypair_name}"
        key = @ec2.key_pairs.create(name: keypair_name)
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
      logger.info "#{@stamp} Using key: #{keypair_name}"
      if key && key.private_key
        @node.ssh_key = key.private_key
        @node.ssh_key_fingerprint = key.fingerprint
        if @parent_resource["node/#{@node.id}"].post(ssh_key: @node.raw_ssh_key, ssh_key_fingerprint: @node.ssh_key_fingerprint)
          if (ssh_key_path = Powernode.config('ssh_key_path'))
            FileUtils.mkdir_p(ssh_key_path)
            FileUtils.touch(@node.ssh_key_file)
            FileUtils.chmod(0600, @node.ssh_key_file)
            File.open(@node.ssh_key_file, 'w') { |f| f.write(@node.ssh_key) }
          end
        end
      end
    end
    user_data = <<END
ID=\"#{@node.id}\"
KEY=\"#{Powernode.config('key')}\"
PARENT=\"#{Powernode.config('proxy_url').nil? ? Powernode.config('parent_url') : Powernode.config('proxy_url')}\"
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
          unless @parent_resource["node/#{@node.id}/instance.json"].post(node_instance: node_instance.to_json)
            @ec2.servers.destroy(aws_instance.id)
          end
        end
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
    end
  end
end
