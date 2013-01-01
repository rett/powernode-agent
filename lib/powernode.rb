require 'logger'
require 'powernode/model_extensions'
require 'powernode/node'
require 'powernode/node_instance'
require 'powernode/node_instance_type'
require 'powernode/node_module'
require 'powernode/node_platform'
require 'powernode/node_provider'
require 'powernode/node_template'

module Powernode
  def self.config(key)
    @config ||= YAML.load_file(File.join(File.dirname(__FILE__), '/../config.yml'))
    @config[key]
  end

  def self.logger_init(file_name, cycle, log_level)
    @logger = Logger.new(File.join(Powernode.config('log_dir'), file_name), cycle)
    @logger.level = Logger.const_get(log_level.upcase)
    @logger
  end

  def self.logger
    @logger ||= begin
      log = Logger.new(STDOUT)
      log.level = Logger::INFO
      log.formatter = Pretty.new
      log
    end
  end

  def logger
    Powernode.logger
  end
end
