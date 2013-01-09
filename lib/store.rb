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
require 'sidekiq-unique-jobs'
require 'tmpdir'
require 'powernode'
require 'powernode/models'

class Store
  include Powernode
  include Sidekiq::Worker

  Sidekiq.configure_server do |config|
    config.logger = Powernode.logger_init(Powernode.config('store_logfile'), Powernode.config('log_cycle'), Powernode.config('store_loglevel'))
    config.redis = { namespace: Powernode.config('redis_namespace'), url: Powernode.config('redis_server') }
  end

  sidekiq_options queue: Powernode.config('store_queue'),
                  retry: Powernode.config('store_job_retries'),
                  unique: true,
                  unique_job_expiration: Powernode.config('store_job_expiration')

  def perform(message)
    params = ActiveSupport::JSON.decode(message)
    @node = Node.new(params['node'])
    @node_module = NodeModule.new(params['node_module'])
    @operation = params['operation']
    begin
      @node_resource = RestClient::Resource.new(Powernode.config('parent_url') + '/api/v1/node',
                                                Powernode.config('id'),
                                                Powernode.config('key'))
      logger.info "Performing #{@operation} on module #{@node_module.id}..."
      send("do_#{@operation}") if respond_to?("do_#{@operation}")
    end
  end

  protected

  def do_transfer
    module_file_name = "#{Powernode.config('module_path')}/#{@node_module.data_file_name}"
    logger.info "Attempting to download #{@node_module.data_file_name}..."
    begin
      FileUtils.mkdir_p(Powernode.config('module_path'))
      FileUtils.touch(module_file_name + '.tmp')
    rescue Exception => e
      logger.error "Exception: #{e}"
    end
    begin
      File.open(module_file_name + '.tmp', 'w') do |f|
        f.write(@node_resource["/module/#{@node_module.id}.html"].get(params: { node_id: @node.id }))
      end
      if @node_module.checksum == Digest::SHA2.new(Powernode.config('checksum_bitlength') || 256).hexdigest(File.binread(module_file_name + '.tmp'))
        FileUtils.move(module_file_name + '.tmp', module_file_name)
      elsif File.exists?(module_file_name + '.tmp')
        FileUtils.rm_f(module_file_name + '.tmp')
      end
    rescue Exception => e
      logger.error "Exception: #{e}"
    end
  end
end
