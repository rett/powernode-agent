class NodeArchitecture
  include Her::Model
  parse_root_in_json true

  belongs_to :account

  def do_create_image(job = {})
    if (operation = Operation.find(job['id']))
      Powernode.logger.info "Creating image for architecture #{id}."
      image_dir = image_prepare!
      FileUtils.mkdir_p(File.join(image_dir, 'boot', 'syslinux'))
      begin
        image_file = Tempfile.new([id, '.img'])
        image_file_size = (`sudo du -bs #{image_dir} | cut -f1`.to_i * 1.15).to_i
        image_file_blocks = image_file_size / Powernode.config(:image_blocksize).to_i
        image_dir_mount = Dir.mktmpdir
        system *%W[sudo dd if=/dev/zero of=#{image_file.path} bs=#{Powernode.config(:image_blocksize).to_i} count=#{image_file_blocks}]
        system *%W[sudo mkfs.ext4 -F #{image_file.path}]
        system *%W[sudo mount -o loop #{image_file.path} #{image_dir_mount}]
        image_dir_device = `sudo losetup -j #{image_file.path}`.split(':').first
        system *%W[sudo cp -a #{File.join(image_dir, '.')} #{image_dir_mount}]
        system *%W[sudo dd bs=440 conv=notrunc count=1 if=/usr/lib/syslinux/mbr.bin of=#{image_dir_device}]
        system *%W[sudo extlinux --install #{image_dir_mount}/boot]
        system *%W[sudo umount -l #{image_dir_device}]
        FileUtils.remove_entry_secure(image_dir_mount)
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      if image_file && image_file.size > 0
        payload = { image: Faraday::UploadIO.new(image_file.path, 'application/octet-stream') }
        response = Powernode.server.post("node_architectures/#{id}/upload/image", payload)
        if response.status == 200
          operation.add_event!(:info, "Image created for architecture #{name}.")
        else
          operation.add_event!(:danger, "Failed to create image for architecture #{name}.")
        end
      end
      FileUtils.remove_entry_secure(image_file)
      FileUtils.remove_entry_secure(image_dir)
    end
  end


  def init_sync!
    init_dir = Powernode.config(:init_dir)
    FileUtils.mkdir_p(init_dir) unless Dir.exist?(init_dir)
    %w[kernel ramdisk].each do |resource|
      init_resource = File.join(init_dir, "#{id}.#{resource}")
      resource_checksum = self.send("#{resource}_checksum")
      calculated_checksum = File.exists?(init_resource) ? Digest::SHA2.new(Powernode.config(:checksum_bitlength)).file(init_resource).hexdigest : nil
      if resource_checksum.present? && resource_checksum != calculated_checksum
        begin
          File.open(init_resource, File::RDWR|File::CREAT, 0644) do |f|
            if f.flock(File::LOCK_NB|File::LOCK_EX)
              response = Powernode.server.get("node_architectures/#{id}/download/#{resource}")
              if response.status == 200
                f.write(response.body)
                f.flush
                f.truncate(f.pos)
              end
            else
              false
            end
          end
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
      end
    end
  end

  def image_prepare!
    sleep 1 until init_sync!
    init_dir = Powernode.config(:init_dir)
    begin
      FileUtils.mkdir_p(init_dir) unless Dir.exist?(init_dir)
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    begin
      image_dir = Dir.mktmpdir
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    FileUtils.mkdir_p(File.join(image_dir, 'boot'))
    begin
      FileUtils.cp(File.join(init_dir, "#{id}.kernel"), File.join(image_dir, 'boot', 'kernel'))
      FileUtils.cp(File.join(init_dir, "#{id}.ramdisk"), File.join(image_dir, 'boot', 'ramdisk'))
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    FileUtils.mkdir_p(File.join(image_dir, 'boot', 'syslinux'))
    syslinux_cfg_file = File.join(image_dir, 'boot', 'syslinux', 'syslinux.cfg')
    begin
      File.open(syslinux_cfg_file, File::RDWR|File::CREAT, 0644) do |f|
        f.flock(File::LOCK_EX)
        f << "DEFAULT Node_Alchemy_Init\n" +
             "LABEL Node_Alchemy_Init\n" +
             "LINUX /boot/kernel\n" +
             "INITRD /boot/ramdisk\n" +
             "APPEND console=tty0 console=ttyS0,115200n8\n"
        f.flush
        f.truncate(f.pos)
      end
    end
    image_dir
  end
end
