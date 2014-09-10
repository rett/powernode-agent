require 'rubygems'
require 'bundler/setup'
require 'active_support/core_ext/string/strip'
require 'active_support/core_ext/numeric/bytes'
require 'active_support/time'
require 'erb'
require 'faraday'
require 'faraday_middleware'
require 'find'
require 'fog'
require 'her'
require 'json'
require 'log4r'
require 'log4r/outputter/rollingfileoutputter'
require 'log4r/outputter/syslogoutputter'
require 'net/ssh'
require 'net/sftp'
require 'openssl'
require 'pony'
require 'sidekiq'
require 'sidekiq-middleware'
require 'syslog'
require 'tmpdir'
require 'uuidtools'

module Powernode
  def self.config(key)
    @config ||= YAML::load(ERB.new(File.read(File.join(File.dirname(__FILE__), '..', 'config.yml'))).result)
    @config[key.to_s]
  end

  def self.logger
    if @logger.nil?
      @logger = Log4r::Logger.new('powernode')
      outputter_options = {}
      outputter_options[:level] = Logger.const_get(Powernode.config(:log_level).upcase)
      case Powernode.config(:log_facility)
      when 'file'
        outputter_options[:filename] = Powernode.config(:log_file) if Powernode.config(:log_file)
        outputter_options[:trunc] = Powernode.config(:log_trunc) if Powernode.config(:log_trunc)
        @logger.outputters = Log4r::FileOutputter.new('sidekiq', outputter_options)
      when 'rollingfile'
        outputter_options[:filename] = Powernode.config(:log_file) if Powernode.config(:log_file)
        outputter_options[:max_backups] = Powernode.config(:log_max_backups) if Powernode.config(:log_max_backups)
        outputter_options[:maxsize] = Powernode.config(:log_maxsize) if Powernode.config(:log_maxsize)
        outputter_options[:maxtime] = Powernode.config(:log_maxtime) if Powernode.config(:log_maxtime)
        outputter_options[:trunc] = Powernode.config(:log_trunc) if Powernode.config(:log_trunc)
        @logger.outputters = Log4r::RollingFileOutputter.new('sidekiq', outputter_options)
      when 'syslog'
        @logger.outputters = Log4r::SyslogOutputter.new('sidekiq', outputter_options)
      end
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

Sidekiq::Logging.logger = Powernode.logger

Sidekiq.configure_client do |config|
  config.redis = { namespace: Powernode.config(:redis_namespace), url: Powernode.config(:redis_server) }
end

Sidekiq.configure_server do |config|
  config.redis = { namespace: Powernode.config(:redis_namespace), url: Powernode.config(:redis_server) }
end
