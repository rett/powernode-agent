#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'powernode'
require_relative 'agent'

Sidekiq.configure_client do |config|
  config.redis = { namespace: PowerNode.config(:redis_namespace), url: PowerNode.config(:redis_server) }
end

class NodePoller
  def initialize
    logger.warn 'Node Poller started.'
    ['TERM', 'INT'].each do |signal|
      trap(signal) do
        Thread.new do
          logger.warn 'Stopping node poller.'
          $shutdown = true
        end
      end
    end
    @parent = RestClient::Resource.new(PowerNode.config(:server_url) + '/api/v1', PowerNode.config(:id), PowerNode.config(:key))
  end

  def enqueue_message(command, node)
    logger.info "Queued #{command} for node #{node.id}." if NodeAgent.perform_async(command: command, node_id: node.id)
  end

  def logger
    if @logger.nil?
      @logger = Logger.new(File.join(PowerNode.config(:log_dir), PowerNode.config(:poller_logfile)), PowerNode.config(:log_cycle))
      @logger.level = Logger.const_get(PowerNode.config(:poller_loglevel).upcase)
    end
    @logger
  end

  def poll
    begin
      logger.info 'Retrieving list of nodes from parent.'
      nodes = JSON.parse(@parent['nodes'].get).map { |n| Node.new(n) }
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

def run!
  poller = NodePoller.new
  loop do
    poller.poll
    exit 0 if $shutdown
  end
end

run!
