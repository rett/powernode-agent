#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'powernode'

class Agent
  include Sidekiq::Worker
  sidekiq_options({ queue: Powernode.config(:agent_queue),
                    retry: Powernode.config(:agent_job_retries),
                    unique: :all,
                    expiration: Powernode.config(:agent_job_expiration) })

  def perform(job)
    @job = job
    @account = Account.find(@job['account_id'])
    send("perform_#{job['command']}") if job['command'] && respond_to?("perform_#{job['command']}")
  end

  def perform_volume_poll
    if (@volume = Volume.find(@job['volume_id']))
      Powernode.logger.info "Polling volume #{@volume.id}."
      case @volume.status
      when 'attached', 'available'
        @volume.check!
      when 'migrating'
        @volume.recover!
      when 'pending', 'provisioning'
        @volume.provision!
      end
      Powernode.logger.info "Polling complete for volume #{@volume.id}."
    end
  end

  def perform_node_poll
    if (@node = Node.find(@job['node_id']))
      Powernode.logger.info "Polling node #{@node.id}."
      if @node.enabled
        @node.physical_instances.each do |node_instance|
          Powernode.logger.info "Checking physical instance #{node_instance.id}."
          node_instance.netboot_sync! if node_instance.private_netboot_enabled?
        end
        Powernode.logger.info "Performing cloud instance check for node #{@node.id}."
        @node.cloud_instances.each do |node_instance|
          node_instance.check!
        end
        Powernode.logger.info "Performing dynamic instance check for node #{@node.id}."
        @node.dynamic_instances.each do |node_instance|
          node_instance.check!
        end
        @node.operations.each do |operation|
          if (@operation = @node.operations.find(operation.id).first)
            @node_instance = @node.node_instances.find(@operation.node_instance_id) if @operation.try(:node_instance_id)
            @node_instance ||= @node.primary_instance
            @node_module = @node_instance.node_modules.find(@operation.node_module_id) if @operation.try(:node_module_id)
            if @operation.pending? && (!@operation.scheduled_at || Time.parse(@operation.scheduled_at) < Time.now)
              @operation.running!
              self.send("do_#{@operation.command}") if self.respond_to?("do_#{@operation.command}")
              @operation.complete!
            elsif @operation.running?
              @account.notifications.create(category: :error, summary: "#{@operation.description} failed unexpectedly!")
              @operation.failed!
            elsif @operation.failed?
              @operation.complete!
            end
          end
        end
        if @node.dynamic_instance_variance > 0
          Powernode.logger.info "Attempting to launch #{@node.dynamic_instance_variance} instances for node #{@node.id}."
          count = @node.dynamic_instance_variance
          if @node.node_instances.count + count > @node.instance_limit
            count = @node.instance_limit - @node.node_instances.count
            Powernode.logger.info "Account instance limit exceeded, reducing count to #{count} instances."
          end
          count.times { @node.launch_instance!('dynamic') }
        elsif @node.dynamic_instance_variance < 0
          Powernode.logger.info "Attempting to destroy #{@node.dynamic_instance_variance.abs} instances for node #{@node.id}."
          @node.terminate_dynamic_instances!(@node.dynamic_instance_variance.abs)
        end
      elsif @node.dynamic_instances.count > 0
        @node.terminate_dynamic_instances!(@node.dynamic_instances.count)
      end
    end
  end

  def do_instance_create
    @node.launch_instance!
  end

  def do_instance_create_image(node_instance = @node_instance)
    node_instance.create_image!(@operation.options)
  end

  def do_instance_terminate(node_instance = @node_instance)
    node_instance.terminate!
  end

  def do_instance_exec(node_instance = @node_instance)
    node_instance.exec!(@command.exec)
  end

  def do_instance_public_ip_associate(node_instance = @node_instance)
    node_instance.public_ip_associate!
  end

  def do_instance_public_ip_disassociate(node_instance = @node_instance)
    node_instance.public_ip_disassociate!
  end

  def do_instance_reboot(node_instance = @node_instance)
    node_instance.reboot!
  end

  def do_instance_start(node_instance = @node_instance)
    node_instance.start!
  end

  def do_instance_stop(node_instance = @node_instance)
    node_instance.stop!
  end

  def do_node_module_build(node_module = @node_module, node_instance = @node_instance)
    node_module.build!(node_instance)
  end

  def do_node_module_commit(node_module = @node_module, node_instance = @node_instance)
    node_module.commit!(node_instance)
  end

  def do_send_ssh_key
    @node.send_ssh_key!(@operation.options)
  end

  def do_sync_cloud_instances
    @node.cloud_instances.each { |node_instance| node_instance.sync! }
  end

  def do_volume_create
    Powernode.logger.info "Creating volume on instance #{@node_instance}."
  end

  def do_volume_destroy
    Powernode.logger.info "Destroying volume #{@volume}."
  end
end
