#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'powernode'

class Store
  include Sidekiq::Worker
  sidekiq_options({ queue: Powernode.config(:store_queue),
                    retry: Powernode.config(:store_job_retries),
                    unique: true,
                    expiration: Powernode.config(:store_job_expiration) })

  def perform(job)
    @job = job
    @node_module = NodeModule.find(@job['node_module_id'])
    send("do_#{job['command']}") if job['command'] && respond_to?("perform_#{job['command']}")
  end

  def do_transfer_module
    Powernode.logger.info "Attempting to download #{@node_module.data_file_name}"
    module_dir = File.join(Powernode.config(:module_dir), @node_module.uuid_partition)
    module_file = File.join(module_dir, @node_module.data_file_name)
    module_tmp = Tempfile.new([@node_module.id, '.mo'])
    begin
      File.open(module_tmp, File::RDWR|File::CREAT, 0644) do |f|
        f.flock(File::LOCK_EX)
        f.write(Powernode.server.get("node_modules/#{@node_module.id}/download/data").body)
        f.flush
        f.truncate(f.pos)
      end
      if File.exist?(module_tmp)
        calculated_checksum = Digest::SHA2.new(Powernode.config(:checksum_bitlength) || 256).file(module_tmp).hexdigest
        if @node_module.data_checksum == calculated_checksum
          if Dir.exist?(module_dir)
            FileUtils.rm(Dir.glob(File.join(module_dir, "#{@node_module.id}-*")))
          else
            FileUtils.mkdir_p(module_dir)
          end
          FileUtils.move(module_tmp, module_file)
        else
          module_tmp.unlink
        end
      end
    rescue => e
      logger.error "Exception: #{e}"
    end
  end
end
