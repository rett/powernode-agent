#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
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
require 'sidekiq-encryptor'
require 'sidekiq-unique-jobs'
require 'tmpdir'
require 'powernode'
require 'powernode/models'

class Store
  include PowerNode
  include Sidekiq::Worker

  Sidekiq.configure_server do |config|
    config.redis = { namespace: PowerNode.config(:redis_namespace), url: PowerNode.config(:redis_server) }
    config.server_middleware do |chain|
      chain.add Sidekiq::Encryptor::Server, key: PowerNode.config('redis_encryption_key') if PowerNode.config('redis_encryption_key')
    end
    config.client_middleware do |chain|
      chain.add Sidekiq::Encryptor::Client, key: PowerNode.config('redis_encryption_key') if PowerNode.config('redis_encryption_key')
    end
  end

  sidekiq_options queue: PowerNode.config(:store_queue),
                  retry: PowerNode.config(:store_job_retries),
                  unique: true,
                  unique_job_expiration: PowerNode.config(:store_job_expiration)

  def perform(message)
    params = ActiveSupport::JSON.decode(message)
    @node = Node.new(params['node'])
    @node_module = NodeModule.new(params['node_module'])
    @operation = params['operation']
    begin
      @node_resource = RestClient::Resource.new(PowerNode.config(:parent_url) + '/api/v1/node',
                                                PowerNode.config(:id),
                                                PowerNode.config(:key))
      logger.info "Performing #{@operation} on module #{@node_module.id}."
      send("do_#{@operation}") if respond_to?("do_#{@operation}")
    end
  end

  protected

  def do_transfer
    module_file_name = "#{PowerNode.config(:module_path)}/#{@node_module.data_file_name}"
    logger.info "Attempting to download #{@node_module.data_file_name}."
    begin
      FileUtils.mkdir_p(PowerNode.config(:module_path))
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
