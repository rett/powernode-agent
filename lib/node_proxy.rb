#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'csv'
require 'json'
require 'logger'
require 'rack/auth/basic'
require 'rack/auth/abstract/request'
require 'redis'
require 'restclient'
require 'sidekiq'
require 'sidekiq-encryptor'
require 'sinatra/base'
require 'sinatra/multi_route'
require 'sinatra/synchrony'
require 'powernode'
require 'node_store'
require 'thin'

Sidekiq.configure_client do |config|
  config.redis = { namespace: PowerNode.config(:redis_namespace), url: PowerNode.config(:redis_server) }
  config.client_middleware do |chain|
    chain.add Sidekiq::Encryptor::Client, key: PowerNode.config('redis_encryption_key') if PowerNode.config('redis_encryption_key')
  end
end

Redis.current = Sidekiq::RedisConnection

class NodeProxy < Sinatra::Base
  include PowerNode
  register Sinatra::Synchrony
  register Sinatra::MultiRoute

  configure :development, :production, :test do
    enable :logging
    enable :sessions
  end

  get %r{/api/v1/node/(?<node>\h{8}-\h{4}-\h{4}-\h{4}-\h{12})/modules.csv} do
    auth = Rack::Auth::Basic::Request.new(@env)
    id, key = auth.credentials
    node = params[:node]
    parent_resource = RestClient::Resource.new(PowerNode.config(:node_server_url) + '/api/v1/node/' + node, id, key)
    begin
      node_modules = JSON.parse(parent_resource['modules'].get).map { |m| NodeModule.new(m) }
    rescue => e
      logger.error "Exception: #{e.message}"
    end
    if node_modules
      node_modules.each do |node_module|
        if node_module.data_file_name
          module_file_name = File.join(PowerNode.config(:module_dir), node_module.uuid_partition, node_module.data_file_name)
          unless File.exist?(module_file_name) && node_module.data_checksum == Digest::SHA2.new(PowerNode.config(:checksum_bitlength) || 256).hexdigest(File.binread(module_file_name))
            enqueue_message({ node: node, node_module: node_module, operation: 'transfer_module' })
            node_module.status = 'WAIT'
          end
        end
      end
      csv_string = CSV.generate({ force_quotes: true }) do |csv|
        node_modules.each do |node_module|
          csv << [node_module.status,
                  node_module.id,
                  node_module.data_file_version,
                  node_module.data_checksum] if node_module.data_checksum
        end
      end
      content_type('text/csv')
      csv_string
    else
      status 202
    end
  end

  get %r{/api/v1/node/(?<node>\w{8}-\w{4}-\w{4}-\w{4}-\w{12})/module/(?<node_module>\w{8}-\w{4}-\w{4}-\w{4}-\w{12}).html} do
    auth = Rack::Auth::Basic::Request.new(@env)
    id, key = auth.credentials
    node = params[:node]
    node_module_id = params[:node_module]
    parent_resource = RestClient::Resource.new(PowerNode.config(:node_server_url) + '/api/v1/node/' + node, id, key)
    begin
      node_module = NodeModule.new(JSON.parse(parent_resource["module/#{node_module_id}"].get))
    rescue => e
      logger.error "Exception: #{e.message}"
    end
    if node_module
      module_file_name = File.join(PowerNode.config(:module_dir), node_module.uuid_partition, node_module.data_file_name)
      if File.exist?(module_file_name) && node_module.data_checksum == Digest::SHA2.new(PowerNode.config(:checksum_bitlength) || 256).hexdigest(File.binread(module_file_name))
        logger.info "Sending module: #{node_module.id}, #{module_file_name}"
        send_file(module_file_name)
      else
        enqueue_message({ node: node, node_module: node_module, operation: 'transfer_module' })
        status 202
      end
    end
  end

  route :get, :post, '/api/v1/*' do |path|
    if PowerNode.config(:proxy_redirect) == 'true'
      logger.info "Redirecting request to #{PowerNode.config(:node_server_url)}/api/v1/#{path}."
      begin
        redirect PowerNode.config(:node_server_url) + "/api/v1/#{path}"
      rescue => e
        logger.error "Exception: #{e.message}"
      end
    else
      auth = Rack::Auth::Basic::Request.new(@env)
      node, key = auth.credentials
      parent_request = RestClient::Resource.new(PowerNode.config(:node_server_url) + '/api/v1/' + params[:splat].join, node, key)
      begin
        logger.info "Forwarding #{request.env['REQUEST_METHOD']} #{request.env['REQUEST_PATH']}"
        method = request.env["REQUEST_METHOD"].gsub(/\W/, '').downcase.to_sym
        parent_request.send(method)
      end
    end
  end

  private

  def enqueue_message(message)
    logger.info "Queued #{operation} for module #{node_module.id}." if Store.perform_async(message.to_json)
  end

  def logger
    if @logger.nil?
      @logger = Logger.new(File.join(PowerNode.config(:log_dir), PowerNode.config(:node_proxy_logfile)), PowerNode.config(:log_cycle))
      @logger.level = Logger.const_get(PowerNode.config(:node_proxy_loglevel).upcase)
    end
    @logger
  end

  def run!
    rack_handler_config = { Host: PowerNode.config(:node_proxy_ip), Port: PowerNode.config(:node_proxy_port) }
    ssl_options = {
        cert_chain_file: File.join(PowerNode.config(:ssl_chain_file)),
        private_key_file: File.join(PowerNode.config(:ssl_key_file))
    }
    Rack::Handler::Thin.run(self, rack_handler_config) do |server|
      if PowerNode.config(:ssl_enabled)
        server.ssl = true
        server.ssl_options = ssl_options
      end
    end
  end
end

NodeProxy.run!
