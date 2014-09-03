require 'rubygems'
require 'bundler/setup'
require 'active_support/core_ext/string/strip'
require 'active_support/time'
require 'faraday'
require 'find'
require 'fog'
require 'her'
require 'json'
require 'net/ssh'
require 'net/sftp'
require 'openssl'
require 'pony'
require 'sidekiq'
require 'sidekiq-middleware'
require 'tmpdir'
require 'uuidtools'

module Powernode
  def self.config(key)
    @config ||= YAML.load_file(File.join(File.dirname(__FILE__), '..', 'config.yml'))
    @config[key.to_s]
  end

  def self.logger
    if @logger.nil?
      @logger = Logger.new(File.join(Powernode.config(:log_dir), Powernode.config(:log_file)), Powernode.config(:log_cycle))
      @logger.level = Logger.const_get(Powernode.config(:log_level).upcase)
    end
    @logger
  end

  def self.server
    if @server.nil?
      @server = Faraday.new(url: Powernode.config(:server_url) + '/api/agent_v1') do |connection|
        connection.basic_auth Powernode.config(:id), Powernode.config(:key)
        connection.request :multipart
        connection.request :url_encoded
        connection.adapter Faraday.default_adapter
      end
    end
    @server
  end
end

Her::API.setup url: Powernode.config(:server_url) + '/api/agent_v1' do |connection|
  connection.use Faraday::Request::BasicAuthentication, Powernode.config(:id), Powernode.config(:key)
  connection.use Faraday::Request::UrlEncoded
  connection.use Her::Middleware::DefaultParseJSON
  connection.use Faraday::Adapter::NetHttp
end

require_relative 'powernode/extensions'
require_relative 'powernode/net-ssh'
require_relative 'powernode/errors'
require_relative 'powernode/models'

case Powernode.config('smtp_method')
when 'sendmail'
  Pony.options = { from: Powernode.config(:smtp_from_email), via: :sendmail }
when 'smtp'
  Pony.options = { from: Powernode.config(:smtp_from_email), via: :smtp,
                   via_options: { address:              Powernode.config(:smtp_server),
                                  port:                 Powernode.config(:smtp_port),
                                  domain:               Powernode.config(:smtp_domain),
                                  user_name:            Powernode.config(:smtp_user_name),
                                  password:             Powernode.config(:smtp_password),
                                  authentication:       Powernode.config(:smtp_authentication),
                                  enable_starttls_auto: Powernode.config(:smtp_enable_starttls_auto) } }
end

Sidekiq.configure_client do |config|
  config.redis = { namespace: Powernode.config(:redis_namespace), url: Powernode.config(:redis_server) }
end

Sidekiq.configure_server do |config|
  config.redis = { namespace: Powernode.config(:redis_namespace), url: Powernode.config(:redis_server) }
end
