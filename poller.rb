#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'json'
require 'resque'
require 'manager'

$logger = Logger.new(File.join(File.dirname(__FILE__) + "/log/poller.log"), "daily")
$logger.level = Logger.const_get(APP_CONFIG['loglevel'].upcase)
$queue = Resque.queue_from_class(Manager)

trap("INT") do
  $logger.warn "Stopping poller..."
  $shutdown = true
end
trap("TERM") do
  $logger.warn "Stopping poller..."
  $shutdown = true
end

$logger.warn "Poller started."

node_poller_resource = RestClient::Resource.new("#{APP_CONFIG['parent_url']}/manage/platform",
                                                APP_CONFIG['identifier'],
                                                APP_CONFIG['passphrase'])
def enqueue_message(node, node_platform, operation)
  message = { :node => node,
              :node_platform => node_platform,
              :operation => operation }.to_json
  queue = Resque.peek($queue, 0, Resque.size($queue))
  unless queue.is_a?(Array) && queue.size > 0 && queue.map {|i| i["args"]}.flatten.include?(message)
    $logger.info "Queueing #{operation} for node #{node}..."
    Resque.enqueue(Manager, message)
  end
end

loop do
  start_time = Time.now
  begin
    node_poller, node_platforms = JSON.parse(node_poller_resource.get(:accept => :json))
  rescue => e
    $logger.error "Exception: #{e.message}"
  end
  if node_platforms.is_a?(Array)
    node_platforms.each do |node_platform|
      node_platform_resource = RestClient::Resource.new("#{APP_CONFIG['parent_url']}/manage/platform/#{node_platform}",
                                                        APP_CONFIG['identifier'],
                                                        APP_CONFIG['passphrase'])
      begin
        nodes = JSON.parse(node_platform_resource["nodes"].get(:accept => :json))
      rescue => e
        $logger.error "Exception: #{e.message}"
        nodes = nil
      end
      if nodes.is_a?(Array)
        nodes.each do |node|
          enqueue_message(node, node_platform, 'poll_cloud_instances')
          enqueue_message(node, node_platform, 'poll_physical_instances')
        end
      end
    end
  end
  if $shutdown
    $logger.warn "Poller stopped."
    exit 0
  end
  interval = (node_poller['poll_interval'] - (Time.now - start_time)).to_i + 1
  if interval > 0
    $logger.info "Sleeping #{interval} seconds (Poll cycle took #{node_poller['poll_interval'] - interval} seconds, interval is #{node_poller['poll_interval']} seconds)..."
    sleep interval
  elsif node_poller['poll_interval'] != 0
    $logger.info "Warning: Poll interval #{node_poller['poll_interval']} appears to be at least #{interval.abs} seconds too short."
  end
end
