class NodeInstance
  include Her::Model
  include Powernode::Encryption

  belongs_to :node
  belongs_to :node_instance_type
  has_many :node_modules

  delegate :account, to: :node
  delegate :admin_user, to: :node
  delegate :ssh_key, to: :node
  delegate :ssh_key_file, to: :node

  attributes :image

  parse_root_in_json true

  delegate :provider, to: :node

  def identity
    <<-EOF.strip_heredoc
      ID=#{id}
      KEY=#{agent_key}
      SERVER=#{node.proxy_url.present? ? node.proxy_url : Powernode.config(:server_url)}/api/node_v1
    EOF
  end

  def identity_parameters
    "ID=#{id} " +
    "KEY=#{agent_key} " +
    "SERVER=#{node.proxy_url.present? ? node.proxy_url : Powernode.config(:server_url)}/api/node_v1 "
  end

  def instance
    unless @instance
      begin
        @instance = provider.compute.servers.get(entity)
        self.status = 'terminated' unless @instance
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
    @instance
  end

  def ssh_ip_address
    unless @ssh_ip_address
      begin
        @ssh_ip_address = instance.ssh_ip_address
        @ssh_ip_address ||= instance.public_ip_address
        @ssh_ip_address ||= instance.private_ip_address
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
    @ssh_ip_address
  end

  def check!
    if instance
      Powernode.logger.info "Updating cloud instance #{id}."
      begin
        self.private_ip_address = instance.private_ip_address
        self.public_ip_address = instance.public_ip_address
        self.status = instance.state
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      save if changed?
    end
    case status
    when 'terminated'
      self.destroy
    end
  end

  def create_image!(options)
    image_format = options[:image_format]
    init_dir = Powernode.config(:init_dir)
    Powernode.logger.info "Creating #{image_format} image for instance #{id}."
    begin
      FileUtils.mkdir_p(init_dir) unless Dir.exist?(init_dir)
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    begin
      tmp_dir = Dir.mktmpdir
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    FileUtils.mkdir_p(File.join(tmp_dir, 'boot'))
    begin
      FileUtils.cp(File.join(init_dir, "#{node.node_architecture.id}.kernel"), File.join(tmp_dir, 'boot', 'kernel'))
      FileUtils.cp(File.join(init_dir, "#{node.node_architecture.id}.ramdisk"), File.join(tmp_dir, 'boot', 'ramdisk'))
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    node_identity_file = File.join(tmp_dir, 'identity.cfg')
    begin
      File.open(node_identity_file, File::RDWR|File::CREAT, 0644) do |f|
        f.flock(File::LOCK_EX)
        f.puts(identity)
        f.flush
        f.truncate(f.pos)
      end
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    node_config_file = File.join(tmp_dir, 'node.cfg')
    begin
      File.open(node_config_file, File::RDWR|File::CREAT, 0644) do |f|
        f.flock(File::LOCK_EX)
        f.puts(config)
        f.flush
        f.truncate(f.pos)
      end
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    FileUtils.mkdir_p(File.join(tmp_dir, 'boot', 'syslinux'))
    syslinux_cfg_file = File.join(tmp_dir, 'boot', 'syslinux', 'syslinux.cfg')
    begin
      File.open(syslinux_cfg_file, File::RDWR|File::CREAT, 0644) do |f|
        f.flock(File::LOCK_EX)
        f << "DEFAULT alchemy\n" +
            "LABEL alchemy\n" +
            "LINUX /boot/kernel\n" +
            "INITRD /boot/ramdisk\n"
        if private_ip_static
          f << "APPEND ip=#{private_ip_address}:" +
              ":" +
              "#{private_ip_gateway}:" +
              "#{private_ip_netmask}:" +
              "#{name}:" +
              "#{private_ip_device}:" +
              "off " +
              "DNS_PRIMARY=#{private_ip_primary_dns} " +
              "DNS_SECONDARY=#{private_ip_secondary_dns} " +
              "DNS_DOMAIN=#{private_ip_domain}\n"
        end
        f.flush
        f.truncate(f.pos)
      end
    end
    case image_format
    when 'img'
      begin
        image_file = Tempfile.new(["#{id}", '.img'])
        image_file_size = (`sudo du -bs #{tmp_dir} | cut -f1`.to_i * 1.15).to_i
        image_file_blocks = image_file_size / Powernode.config(:image_blocksize).to_i
        tmp_dir_mount = Dir.mktmpdir
        system *%W[sudo dd if=/dev/zero of=#{image_file.path} bs=#{Powernode.config(:image_blocksize).to_i} count=#{image_file_blocks}]
        system *%W[sudo mkfs.ext4 -F #{image_file.path}]
        system *%W[sudo mount -o loop #{image_file.path} #{tmp_dir_mount}]
        tmp_dir_device = `sudo losetup -j #{image_file.path}`.split(':').first
        system *%W[sudo cp -a #{File.join(tmp_dir, '.')} #{tmp_dir_mount}]
        system *%W[sudo dd bs=440 conv=notrunc count=1 if=/usr/lib/syslinux/mbr.bin of=#{tmp_dir_device}]
        system *%W[sudo extlinux --install #{tmp_dir_mount}/boot]
        system *%W[sudo umount -l #{tmp_dir_device}]
        FileUtils.remove_entry_secure(tmp_dir_mount)
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    when 'iso'
      begin
        FileUtils.cp('/usr/lib/syslinux/isolinux.bin', File.join(tmp_dir, 'boot'))
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      begin
        image_file = Tempfile.new(["#{id}", '.img'])
        system *%W[sudo mkisofs -o #{image_file.path} -V #{name} -b boot/isolinux.bin -c boot/syslinux/boot.cat -r -J -l -quiet -relaxed-filenames -no-emul-boot -boot-load-size 4 -boot-info-table #{tmp_dir}]
        system *%W[sudo isohybrid #{image_file.path} --entry 1 --type 0x83]
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
    if image_file && image_file.size > 0
      payload = { image_format: image_format, image: Faraday::UploadIO.new(image_file.path, 'application/octet-stream') }
      response = Powernode.server.post("node_instances/#{id}/upload/image", payload)
      if response.status == 200
        account.notifications.create(category: :notice, summary: "#{image_format.upcase} image created for instance #{id}.")
      else
        account.notifications.create(category: :error, summary: "Failed to create #{image_format.upcase} image for instance #{id}.")
      end
    end
    FileUtils.remove_entry_secure(image_file)
    FileUtils.remove_entry_secure(tmp_dir)
  end

  def exec!(command)
    Powernode.logger.info "Executing (#{command}) on #{name}."
    begin
      session = Net::SSH.start(ssh_ip_address, node.admin_user, key_data: ssh_key)
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    response = ''
    begin
      session.open_channel do |channel|
        channel.exec("sudo #{command}") do |ch, success|
          channel.on_data do |ch, data|
            response = data
          end
        end
      end
      session.loop
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    response
  end

  def netboot_sync!
    init_dir = Powernode.config(:init_dir)
    pxelinux_dir = File.join(init_dir, 'pxelinux.cfg')
    FileUtils.mkdir_p(pxelinux_dir) unless Dir.exist?(pxelinux_dir)
    if private_netboot_enabled? && private_mac_address.present?
      Powernode.logger.info "Synchronizing netboot config for instance #{id}."
      netboot_cfg_file = File.join(pxelinux_dir, private_mac_address)
      if File.exist?(netboot_cfg_file)
        file_updated_at = open(netboot_cfg_file, 'r') { |f| f.each_line.find { |line| line.include?('# Updated: ') }.try(:match, /(\d\d\d\d)-(\d\d)-(\d\d)T(.*)-(\d\d):(\d\d)/) }
      end
      if File.exist?(netboot_cfg_file) && (File.mtime(netboot_cfg_file) < Time.now - Powernode.config(:data_expiration) || updated_at == file_updated_at)
        FileUtils.touch(netboot_cfg_file)
      else
        kernel_file_name = "#{node.node_architecture.id}.kernel"
        ramdisk_file_name = "#{node.node_architecture.id}.ramdisk"
        begin
          File.open(netboot_cfg_file, File::RDWR|File::CREAT, 0644) do |f|
            f.flock(File::LOCK_EX)
            f << "# Updated: #{updated_at}\n" +
              "DEFAULT alchemy\n" +
              "LABEL alchemy\n" +
              "LINUX /boot/#{kernel_file_name}\n" +
              "INITRD /boot/#{ramdisk_file_name}\n" +
              "APPEND #{identity_parameters} "
            if private_ip_static
              f << "ip=" +
                "#{private_ip_address}:" +
                ":" +
                "#{private_ip_gateway}:" +
                "#{private_ip_netmask}:" +
                "#{name}:" +
                "#{private_ip_device}:" +
                "off " +
                "DNS_PRIMARY=#{private_ip_primary_dns} " +
                "DNS_SECONDARY=#{private_ip_secondary_dns} " +
                "DNS_DOMAIN=#{private_ip_domain}\n"
            else
              f << "\n"
            end
            f.flush
            f.truncate(f.pos)
          end
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
      end
    end
  end

  def public_ip_associate!
    Powernode.logger.info "Associating public IP for instance #{id}."
    begin
      address = provider.compute.addresses.find { |a| a.ip == public_ip_address } if public_ip_address.present?
      address ||= provider.compute.addresses.find { |a| a.instance_id.nil? }
      address ||= provider.compute.addresses.create
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    if address
      begin
        instance.service.associate_address(address.ip)
        self.public_ip_address = address.ip
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      save
      account.notifications.create(category: :notice, summary: "Associated IP for instance #{name}.")
    end
  end

  def public_ip_disassociate!
    begin
      address = self.instance.public_ip_address
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    unless address.nil?
      Powernode.logger.info "Disassociating public IP for instance #{id}."
      begin
        instance.service.disassociate_address(public_ip_address)
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      account.notifications.create(category: :notice, summary: "Disassociated IP from instance #{name}.")
    end
  end

  def reboot!
    Powernode.logger.info "Rebooting instance #{id}."
    begin
      instance.reboot
      account.notifications.create(category: :notice, summary: "Instance #{name} rebooting.")
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
  end

  def start!
    Powernode.logger.info "Starting instance #{id}."
    begin
      instance.start
      account.notifications.create(category: :notice, summary: "Instance #{name} starting.")
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
  end

  def stop!
    Powernode.logger.info "Stopping instance #{id}."
    begin
      instance.stop
      account.notifications.create(category: :notice, summary: "Instance #{name} stopping.")
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
  end

  def sync!
    Powernode.logger.info "Syncing instance #{id}."
    if ssh_ip_address && node.key
      begin
        session = Net::SSH.start(ssh_ip_address, node.admin_user, key_data: node.ssh_key)
        session.exec!('sudo /usr/sbin/ipn -S')
        account.notifications.create(category: :notice, summary: "Instance #{name} synced.")
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
  end

  def terminate!
    Powernode.logger.info "Terminating instance #{id}."
    begin
      self.instance.destroy
      account.notifications.create(category: :notice, summary: "Instance #{name} terminating.")
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
  end
end
