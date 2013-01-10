#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'json'
require 'restclient'
require 'sidekiq'
require 'sidekiq-unique-jobs'
require 'powernode'
require 'powernode/models'
require 'manager'

Sidekiq.configure_client do |config|
  config.redis = { namespace: Powernode.config('redis_namespace'), url: Powernode.config('redis_server') }
end

class Poller
  include Powernode
  Powernode.logger_init(Powernode.config('poller_logfile'), Powernode.config('log_cycle'), Powernode.config('poller_loglevel'))

  def initialize
    trap('INT') do
      logger.warn 'Stopping poller...'
      $shutdown = true
    end
    trap('TERM') do
      logger.warn 'Stopping poller...'
      $shutdown = true
    end
    logger.info "Poller started."
  end

  def poll
    parent_resource = RestClient::Resource.new(Powernode.config('parent_url') + '/api/v1',
                                               Powernode.config('id'),
                                               Powernode.config('key'))
    begin
      nodes = JSON.parse(parent_resource['nodes'].get).collect { |n| Node.new(n) }
    rescue => e
      logger.error "Exception: #{e.message}"
    end
    nodes.is_a?(Array) && nodes.each do |node|
      enqueue_message(:poll_instances, node)
    end
    sleep Powernode.config('poller_interval')
  end

  def enqueue_message(operation, node)
    message = ActiveSupport::JSON.encode({ operation: operation, node: { id: node.id } })
    logger.info "Queued #{operation} for node #{node.id}." if Manager.perform_async(message)
  end
end

poller = Poller.new
loop do
  poller.poll
  if $shutdown
    poller.logger.warn 'Poller stopped.'
    exit 0
  end
end
