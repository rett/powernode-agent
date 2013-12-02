#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'json'
require 'restclient'
require 'sidekiq'
require 'sidekiq-encryptor'
require 'sidekiq-unique-jobs'
require 'powernode'
require 'powernode/models'
require 'manager'

Sidekiq.configure_client do |config|
  config.redis = { namespace: PowerNode.config(:redis_namespace), url: PowerNode.config(:redis_server) }
  config.client_middleware do |chain|
    chain.add Sidekiq::Encryptor::Client, key: PowerNode.config('redis_encryption_key') if PowerNode.config('redis_encryption_key')
  end
end

class Poller
  include PowerNode

  def initialize
    ['TERM', 'INT'].each do |signal|
      trap(signal) do
        Thread.new do
          logger.warn 'Stopping poller.'
          $shutdown = true
        end
      end
    end
    @parent = RestClient::Resource.new(PowerNode.config(:parent_url) + '/api/v1', PowerNode.config(:id), PowerNode.config(:key))
  end

  def enqueue_message(command, node)
    message = ActiveSupport::JSON.encode({ 'command' => command, params: { 'node_id' => node.id } })
    logger.info "Queued #{command} for node #{node.id}." if Manager.perform_async(message)
  end

  def poll
    begin
      logger.info 'Retrieving list of nodes from parent.'
      nodes = JSON.parse(@parent['nodes'].get).collect { |n| Node.new(n) }
    rescue => e
      logger.error "Exception: #{e.message}"
    end

    if nodes.is_a?(Array)
      nodes.each do |node|
        enqueue_message(:poll_node, node)
      end
    end
    sleep PowerNode.config(:poller_interval)
  end
end

def logger
  if @logger.nil?
    @logger = Logger.new(File.join(PowerNode.config(:log_path), PowerNode.config(:poller_logfile)), PowerNode.config(:log_cycle))
    @logger.level = Logger.const_get(PowerNode.config(:poller_loglevel).upcase)
  end
  @logger
end

def run!
  poller = Poller.new
  logger.info 'Poller started.'
  loop do
    poller.poll
    if $shutdown
      logger.warn 'Poller stopped.'
      exit 0
    end
  end
end

run!
