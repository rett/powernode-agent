#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'powernode'

class Agent
  include Sidekiq::Worker
  sidekiq_options({ queue: Powernode.config(:agent_queue),
                    retry: Powernode.config(:agent_job_retries),
                    unique: true,
                    expiration: Powernode.config(:agent_job_expiration) })

  def perform(job)
    if job['operable_type']
      operable_type = job['operable_type'].classify.constantize
      operable = operable_type.find(job['operable_id'])
      if operable.respond_to?('do_' + job['command']) && (!operable.respond_to?(:agent_id) || operable.agent_id == Powernode.config(:id))
        operable.send('do_' + job['command'], job)
      end
    end
  end
end
