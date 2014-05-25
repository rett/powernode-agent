module PowerNode
  def self.config(key)
    @config ||= YAML.load_file(File.join(File.dirname(__FILE__), '..', 'config.yml'))
    @config[key.to_s]
  end
end

require 'rubygems'
require 'bundler/setup'
require 'active_support/core_ext/string/strip'
require 'active_support/time'
require 'find'
require 'fog'
require 'json'
require 'net/ssh'
require 'net/sftp'
require 'openssl'
require 'pony'
require 'restclient'
require 'sidekiq'
require 'sidekiq-middleware'
require 'tmpdir'
require 'uuidtools'
require 'powernode/net-ssh'
require 'powernode/errors'
require 'powernode/models'
