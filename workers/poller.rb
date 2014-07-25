#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'powernode'
require_relative 'agent'

class Poller
  def poll
    Account.all.each do |account|
      account.nodes.each do |node|
        command = 'node_poll'
        begin
          Powernode.logger.info "Queued #{command} for node #{node.id}." if Agent.perform_async({ command: command,
                                                                                                  account_id: account.id,
                                                                                                  node_id: node.id })
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
      end
      account.volumes.each do |volume|
        command = 'volume_poll'
        begin
          Powernode.logger.info "Queued #{command} for volume #{volume.id}." if Agent.perform_async({ command: command,
                                                                                                      account_id: account.id,
                                                                                                      volume_id: volume.id })
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
      end
    end
    perform_cleanup!
    sleep Powernode.config(:poller_interval)
  end
end

def perform_cleanup!
  pxelinux_dir = File.join(Powernode.config(:init_dir), 'pxelinux.cfg')
  Dir.glob(File.join(pxelinux_dir, '??-??-??-??-??-??')) do |f|
    FileUtils.rm(f) if File.mtime(f) < Time.now - Powernode.config(:data_expiration)
  end
end

def run!
  poller = Poller.new
  Powernode.logger.warn 'Poller started.'
  poller.poll while true
  Powernode.logger.warn 'Poller stopped.'
end

run!
