#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'powernode'
require 'csv'
require 'sinatra/base'
require 'sinatra/multi_route'
require 'sinatra/synchrony'
require 'thin'
require_relative 'store'

class Proxy < Sinatra::Base
  register Sinatra::Synchrony
  register Sinatra::MultiRoute

  before do
    @auth = Rack::Auth::Basic::Request.new(@env)
    @instance_id, @instance_key = @auth.credentials
  end

  def node_api
    unless @node_api
      @node_api = Faraday.new(url: Powernode.config(:server_url) + '/api/node_v1') do |connection|
        connection.basic_auth @instance_id, @instance_key
        connection.adapter Faraday.default_adapter
      end
    end
    @node_api
  end

  configure :development, :production, :test do
    enable :logging
    enable :sessions
  end

  get %r{modules.csv} do
    node_instance = NodeInstance.find(@instance_id)
    csv_string = CSV.generate({ force_quotes: true }) do |csv|
      node_instance.node_modules.each do |node_module|
        if node_module.data_file_name
          status = 'ready'
          module_file_name = File.join(Powernode.config(:module_dir), node_module.uuid_partition, node_module.data_file_name)
          calculated_checksum = Digest::SHA2.new(Powernode.config(:checksum_bitlength) || 256).file(module_file_name).hexdigest if File.exist?(module_file_name)
          unless File.exist?(module_file_name) && node_module.data_checksum == calculated_checksum
            queue_transfer!(node_module)
            status = 'wait'
          end
          csv << [status,
                  node_module.id,
                  node_module.data_file_version,
                  node_module.data_checksum] if node_module.data_checksum
        end
      end
    end
    content_type('text/csv')
    csv_string
  end

  get %r{module/(?<node_module_id>\w{8}-\w{4}-\w{4}-\w{4}-\w{12}).html} do
    node_instance = NodeInstance.find(@instance_id)
    if node_instance && (node_module = node_instance.node_modules.find(params[:node_module_id]))
      module_file_name = File.join(Powernode.config(:module_dir), node_module.uuid_partition, node_module.data_file_name)
      calculated_checksum = Digest::SHA2.new(Powernode.config(:checksum_bitlength) || 256).file(module_file_name).hexdigest if File.exist?(module_file_name)
      if File.exist?(module_file_name) && node_module.data_checksum == calculated_checksum
        send_file(module_file_name)
      else
        queue_transfer!(node_module)
        status 202
      end
    end
  end

  route :get, :post, '/api/node_v1/*' do |path|
    begin
      method = request.env["REQUEST_METHOD"].gsub(/\W/, '').downcase.to_sym
      node_api.send(method) { |request| request.url params[:splat].join }.body
    end
  end

  def queue_transfer!(node_module)
    Powernode.logger.info "Queueing module download for #{node_module.id}." if Store.perform_async({ node_module_id: node_module.id, command: 'transfer_module' })
  end

  def run!
    rack_handler_config = { Host: PowerNode.config(:proxy_ip), Port: PowerNode.config(:proxy_port) }
    Rack::Handler::Thin.run(self, rack_handler_config) do |server|
      if PowerNode.config(:ssl_enabled)
        ssl_options = {
            cert_chain_file: File.join(PowerNode.config(:ssl_chain_file)),
            private_key_file: File.join(PowerNode.config(:ssl_key_file))
        }
        server.ssl = true
        server.ssl_options = ssl_options
      end
    end
  end
end

Proxy.run!
