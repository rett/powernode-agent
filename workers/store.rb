#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'fog'
require 'json'
require 'logger'
require 'net/ssh'
require 'net/sftp'
require 'redis'
require 'redis/list'
require 'redis/objects'
require 'restclient'
require 'sidekiq'
require 'sidekiq-middleware'
require 'tmpdir'
require 'powernode'

class NodeStore
  include PowerNode
  include Sidekiq::Worker

  Sidekiq.configure_server do |config|
    config.redis = { namespace: PowerNode.config(:redis_namespace), url: PowerNode.config(:redis_server) }
  end

  sidekiq_options({ queue: PowerNode.config(:store_queue),
                    retry: PowerNode.config(:store_job_retries),
                    unique: :all,
                    expiration: PowerNode.config(:store_job_expiration) })

  def perform(message)
    @params = ActiveSupport::JSON.decode(message)
    @operation = @params['operation']
    begin
      @node_resource = RestClient::Resource.new(PowerNode.config(:server_url) + '/api/v1/node',
                                                PowerNode.config(:id),
                                                PowerNode.config(:key))
      send("do_#{@operation}") if respond_to?("do_#{@operation}")
    end
  end

  protected

  def do_transfer_module
    @node = Node.new(@params['node'])
    @node_module = NodeModule.new(@params['node_module'])
    module_file_name = File.join(PowerNode.config(:module_dir), @node_module.uuid_partition, @node_module.data_file_name)
    logger.info "Attempting to download #{@node_module.data_file_name}."
    begin
      FileUtils.mkdir_p(File.join(PowerNode.config(:module_dir), @node_module.uuid_partition))
      FileUtils.touch(module_file_name + '.tmp')
    rescue => e
      logger.error "Exception: #{e}"
    end
    begin
      File.open(module_file_name + '.tmp', 'w') do |f|
        f.write(@node_resource["/module/#{@node_module.id}.html"].get(params: { node_id: @node.id }))
      end
      if @node_module.checksum == Digest::SHA2.new(PowerNode.config(:checksum_bitlength) || 256).hexdigest(File.binread(module_file_name + '.tmp'))
        FileUtils.move(module_file_name + '.tmp', module_file_name)
      elsif File.exists?(module_file_name + '.tmp')
        FileUtils.rm_f(module_file_name + '.tmp')
      end
    rescue => e
      logger.error "Exception: #{e}"
    end
  end
end
