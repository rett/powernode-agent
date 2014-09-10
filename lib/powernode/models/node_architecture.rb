class NodeArchitecture
  include Her::Model

  parse_root_in_json true

  def init_sync!
    init_dir = Powernode.config(:init_dir)
    FileUtils.mkdir_p(init_dir)
    %w[kernel ramdisk].each do |resource|
      init_resource = File.join(init_dir, "#{id}.#{resource}")
      resource_checksum = self.send("#{resource}_checksum")
      calculated_checksum = Digest::SHA2.new(Powernode.config(:checksum_bitlength)).file(init_resource).hexdigest if File.exists?(init_resource)
      if resource_checksum.present? && resource_checksum != calculated_checksum
        Powernode.logger.info "Downloading #{resource} for architecture #{id}."
        response = Powernode.server.get("architectures/#{id}/download/#{resource}")
        if response.status == 200
          begin
            File.open(init_resource, File::RDWR|File::CREAT, 0644) do |f|
              f.flock(File::LOCK_EX)
              f.write(response.body)
              f.flush
              f.truncate(f.pos)
            end
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
        end
      end
    end
  end
end
