#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'json'
require 'resque'
require 'manager'

$logger = Logger.new(File.join(File.dirname(__FILE__) + "/log/poller.log"), "daily")
$queue = Resque.queue_from_class(Manager)

$logger.info "Started poller."

trap("INT") do
  $logger.warn "Stopped poller."
  $logger.close
  exit
end

node_poller_resource = RestClient::Resource.new("#{APP_CONFIG['parent_url']}/manage/poller",
                                                APP_CONFIG['identifier'],
                                                APP_CONFIG['passphrase'])
loop do
  start_time = Time.now
  begin
    node_poller, node_platforms = JSON.parse(node_poller_resource.get(:accept => :json))
  rescue Exception => e
    $logger.error "Exception: #{e.message}"
    sleep 10
    retry
  end
  if !node_platforms.nil?
    node_platforms.each do |node_platform|
      node_platform_resource = RestClient::Resource.new("#{APP_CONFIG['parent_url']}/manage/platform/#{node_platform}",
                                                        APP_CONFIG['identifier'],
                                                        APP_CONFIG['passphrase'])
      begin
        nodes = JSON.parse(node_platform_resource["nodes"].get(:accept => :json))
      rescue Exception => e
        $logger.error "Exception: #{e.message}"
        sleep 10
        retry
      end
      if !nodes.nil?
        nodes.each do |node|
          message = {:operation => "poll",
                     :node => node,
                     :node_platform => node_platform}.to_json
          queue = Resque.peek($queue, 0, Resque.size($queue))
          unless queue.is_a?(Array) && queue.size > 0 && queue.map {|i| i["args"]}.flatten.include?(message)
            $logger.info "Queueing poll operation for node #{node}..."
            Resque.enqueue(Manager, message)
          end
        end
      end
    end
  end
  interval = (node_poller['poll_interval'] - (Time.now - start_time)).to_i + 1
  if interval > 0
    $logger.info "Sleeping #{interval} seconds (Poll cycle took #{node_poller['poll_interval'] - interval} seconds, interval is #{node_poller['poll_interval']} seconds)..."
    sleep interval
  elsif node_poller['poll_interval'] != 0
    $logger.info "Warning: Poll interval #{node_poller['poll_interval']} appears to be at least #{interval.abs} seconds too short."
  end
end
