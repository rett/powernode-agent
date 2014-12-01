#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'powernode'

class Poller
  def poll
    begin
      Account.all.each do |account|
        command = 'maintenance'
        Agent.perform_async({ command: command, operable_type: 'account', operable_id: account.id })
      end
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    perform_cleanup!
    sleep Powernode.config(:poller_interval)
  end

  private

  def perform_cleanup!
    pxelinux_dir = File.join(Powernode.config(:init_dir), 'pxelinux.cfg')
    Dir.glob(File.join(pxelinux_dir, '??-??-??-??-??-??')) do |f|
      FileUtils.rm(f) if File.mtime(f) < Time.now - Powernode.config(:data_expiration)
    end
  end
end

poller = Poller.new
Powernode.logger.warn 'Poller started.'
poller.poll while true
Powernode.logger.warn 'Poller stopped.'
