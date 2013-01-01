#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '../Gemfile')

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
require 'sinatra/base'
require 'sinatra/multi_route'
require 'sinatra/synchrony'
require 'store'
require 'thin'
require 'powernode'

Powernode.logger_init(Powernode.config('proxy_logfile'), Powernode.config('log_cycle'), Powernode.config('proxy_loglevel'))

Sidekiq.configure_client do |config|
  config.redis = { namespace: Powernode.config('redis_namespace'), url: Powernode.config('redis_server') }
end

Redis.current = Sidekiq::RedisConnection

class Proxy < Sinatra::Base
  include Powernode
  register Sinatra::MultiRoute
  register Sinatra::Synchrony

  configure :production, :development do
    enable :logging
    enable :sessions
  end

  get '/api/v1/node/modules.csv', '/api/v1/node/module/:node_module_id.html' do
    auth = Rack::Auth::Basic::Request.new(@env)
    id, key = auth.credentials
    parent_resource = RestClient::Resource.new(Powernode.config('parent') + '/api/v1/node',
                                               id,
                                               key)
    begin
      @node = Node.new(JSON.parse(parent_resource.get(params: { brief: true })))
      @node_modules = JSON.parse(parent_resource['modules'].get).collect { |m| NodeModule.new(m) }
    rescue => e
      logger.error "Exception: #{e.message}"
    end

    if @node && @node_modules
      @node_modules.each do |node_module|
        module_file_name = File.join(Powernode.config('module_dir'), node_module.data_file_name)
        unless File.exist?(module_file_name) && node_module.checksum == Digest::SHA2.new(Powernode.config('checksum_bitlength') || 256).hexdigest(File.binread(module_file_name))
          node_module.status = 'WAIT'
          enqueue_message(@node, node_module, 'transfer')
        end
      end
      if params['node_module_id']
        if (node_module = @node_modules.select { |m| m.id == params['node_module_id'] }.first)
          module_file_name = File.join(Powernode.config('module_dir'), node_module.data_file_name)
          if node_module.status == 'READY'
            logger.info "Sending module: #{node_module.id}, #{module_file_name}"
            send_file(module_file_name)
          else
            logger.info "Sending status 202"
            status 202
          end
        end
      else
        csv_string = CSV.generate({ force_quotes: true }) do |csv|
          @node_modules.each do |node_module|
            csv << [node_module.status,
                    node_module.id,
                    node_module.data_file_version,
                    node_module.checksum,
                    node_module.name,
                    node_module.init,
                    node_module.effective_priority.to_s.rjust(6, '0'),
                    node_module.reboot_required,
                    node_module.copy_path] if node_module.checksum
          end
        end
        content_type('text/csv')
        csv_string
      end
    else
      status 202
    end
  end

  get '/api/v1/*' do |path|
    #auth = Rack::Auth::Basic::Request.new(@env)
    #node_id, key = auth.credentials
    #parent_resource = RestClient::Resource.new(Powernode.config('parent') + '/api/v1/' + params[:splat].join, node_id, key)
    logger.info "Redirecting request to #{Powernode.config('parent')}/api/v1/#{path}."
    begin
      #parent_resource.get(accept: '*/*')
      redirect Powernode.config('parent') + "/api/v1/#{path}"
    rescue => e
      logger.error "Exception: #{e.message}"
    end
  end

  post '/api/v1/node/modules/' do |path|

  end

  protected

  def enqueue_message(node, node_module, operation)
    message = ActiveSupport::JSON.encode({ node: node, node_module: node_module, operation: operation })
    logger.info "Queued #{operation} for module #{node_module.id}." if Store.perform_async(message)
  end

  run!
end
