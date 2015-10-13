class NodeInstance
  include Her::Model
  attributes :image
  parse_root_in_json true

  belongs_to :node
  belongs_to :provider_connection
  belongs_to :provider_region
  belongs_to :provider_instance_type
  belongs_to :provider_network_subnet
  has_many :node_modules
  has_many :operations
  has_many :provider_network_ips

  delegate :account, to: :node
  delegate :admin_user, to: :node
  delegate :ssh_key, to: :node
  delegate :ssh_key_data, to: :node
  delegate :ssh_key_file, to: :node

  def compute
    provider_connection.compute(provider_region)
  end

  def do_maintenance(job = {})
    case variety
    when 'cloud', 'dynamic'
      if instance
        Powernode.logger.info "Updating cloud instance #{id}."
        begin
          self.private_ip_address = instance.private_ip_address.to_s if self.private_ip_address != instance.private_ip_address.to_s
          self.public_ip_address = instance.public_ip_address.to_s if self.public_ip_address != instance.public_ip_address.to_s
          self.status = instance.state.downcase if status != instance.state.downcase
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        if instance.respond_to?(:tags) && instance.tags['Name'] != name
          compute.tags.create(resource_id: entity, key: 'Name', value: name)
        end
        self.save if changed?
      end
    when 'physical'
      netboot_sync if private_netboot_enabled?
    end
    case status
    when 'terminated'
      self.destroy
    end
    true
  end

  def do_create_image(job = {})
    if (operation = Operation.find(job['id']))
      image_format = job['options']['image_format']
      Powernode.logger.info "Creating #{image_format} image for instance #{id}."
      image_dir = node.node_architecture.image_prepare!
      node_identity_file = File.join(image_dir, 'identity.cfg')
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
      node_config_file = File.join(image_dir, 'node.cfg')
      begin
        File.open(node_config_file, File::RDWR|File::CREAT, 0644) do |f|
          f.flock(File::LOCK_EX)
          f.puts(config)
          f.flush
          f.truncate(f.pos)
          operation.progress!(20)
        end
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      FileUtils.mkdir_p(File.join(image_dir, 'boot', 'syslinux'))
      syslinux_cfg_file = File.join(image_dir, 'boot', 'syslinux', 'syslinux.cfg')
      append = ''
      if private_ip_static
        if private_ip_address.present?
          append += "ip=#{private_ip_address}:" +
              ":" +
              "#{private_ip_gateway}:" +
              "#{private_ip_netmask}:" +
              "#{name}:" +
              "#{private_ip_device}:" +
              "off "
        end
      end
      append += "HOSTNAME=#{name} "
      append += "DNS_PRIMARY=#{private_ip_primary_dns} " if private_ip_primary_dns.present?
      append += "DNS_SECONDARY=#{private_ip_secondary_dns} " if private_ip_secondary_dns.present?
      append += "DNS_DOMAIN=#{private_ip_domain} " if private_ip_domain.present?
      begin
        File.open(syslinux_cfg_file, File::RDWR|File::CREAT, 0644) do |f|
          f.flock(File::LOCK_EX)
          f << "DEFAULT alchemy\n" +
               "LABEL alchemy\n" +
               "LINUX /boot/kernel\n" +
               "INITRD /boot/ramdisk\n" +
               "APPEND #{append}\n"
          f.flush
          f.truncate(f.pos)
          operation.progress!(40)
        end
      end
      case image_format
      when 'img'
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
          operation.progress!(50)
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
      when 'iso'
        begin
          FileUtils.cp('/usr/lib/syslinux/isolinux.bin', File.join(image_dir, 'boot'))
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        begin
          image_file = Tempfile.new([id, '.img'])
          system *%W[sudo mkisofs -o #{image_file.path} -V #{name} -b boot/isolinux.bin -c boot/syslinux/boot.cat -r -J -l -quiet -relaxed-filenames -no-emul-boot -boot-load-size 4 -boot-info-table #{image_dir}]
          operation.progress!(60)
          system *%W[sudo isohybrid #{image_file.path} --entry 1 --type 0x83]
          operation.progress!(80)
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
      end
      if image_file && image_file.size > 0
        payload = { image_format: image_format, image: Faraday::UploadIO.new(image_file.path, 'application/octet-stream') }
        response = Powernode.server.post("node_instances/#{id}/upload/image", payload)
        if response.status == 200
          operation.add_event!(:info, "#{image_format.upcase} image created for instance #{name}.")
        else
          operation.add_event!(:danger, "Failed to create #{image_format.upcase} image for instance #{name}.")
        end
      end
      FileUtils.remove_entry_secure(image_file)
      FileUtils.remove_entry_secure(image_dir)
    end
  end

  def do_exec(job = {})
    if (operation = Operation.find(job['id']))
      operation.progress!(10)
      Powernode.logger.info "Executing (#{job['options']['exec']}) on #{name}."
      begin
        session = Net::SSH.start(ssh_ip_address, node.admin_user, key_data: key.to_pem, paranoid: false)
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      response = ''
      operation.progress!(20)
      begin
        session.open_channel do |channel|
          channel.exec("sudo #{job['options']['exec']}") do |ch, success|
            channel.on_data do |ch, data|
              response = data
            end
          end
        end
        session.loop
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
    response
  end

  def do_public_ip_associate(job = {})
    if (operation = Operation.find(job['id']))
      Powernode.logger.info "Associating public IP for instance #{id}."
      begin
        Powernode.logger.info "Searching for unallocated public IP for instance #{id}."
        case provider_connection.variety
        when 'aws'
          address = [compute.addresses.find { |a| !a.server_id && a.domain == 'vpc' }].first
        else
          address = [compute.addresses.find { |a| !a.instance_id }].first
        end
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      unless address
        begin
          Powernode.logger.info "Allocating public IP for instance #{id}."
          address = compute.addresses.create
        rescue => e
          operation.add_event!(:danger, "Unable to allocate IP for instance #{name}: #{e.message}")
          Powernode.logger.error "Exception: #{e.message}."
        end
      end
      if address
        begin
          ip = address.respond_to?(:public_ip) ? address.public_ip : address.ip
          if address.respond_to?(:allocation_id)
            instance.service.associate_address(entity, nil, nil, address.allocation_id)
          else
            instance.service.associate_address(entity, ip)
          end
          self.public_ip_address = ip
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        save
      end
    end
  end

  def do_public_ip_disassociate(job = {})
    if (operation = Operation.find(job['id']))
      begin
        address = compute.addresses.find { |a| a.respond_to?(:public_ip) ? a.public_ip == public_ip_address : a.ip == public_ip_address }
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      if address.present?
        Powernode.logger.info "Disassociating public IP for instance #{id}."
        begin
          if address.respond_to?(:association_id)
            instance.service.disassociate_address(nil, address.association_id)
          else
            instance.service.disassociate_address(entity, public_ip_address)
          end
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        operation.add_event!(:info, "Disassociated IP #{address} from instance #{name}.")
      end
    end
  end

  def do_reboot(job = {})
    if (operation = Operation.find(job['id']))
      Powernode.logger.info "Rebooting instance #{id}."
      operation.progress!(50)
      begin
        instance.reboot
        operation.add_event!(:info, "Instance #{name} rebooting.")
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
  end

  def do_start(job = {})
    if (operation = Operation.find(job['id']))
      Powernode.logger.info "Starting instance #{id}."
      operation.progress!(50)
      begin
        instance.start
        operation.add_event!(:info, "Instance #{name} starting.")
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
  end

  def do_stop(job = {})
    if (operation = Operation.find(job['id']))
      Powernode.logger.info "Stopping instance #{id}."
      operation.progress!(50)
      begin
        instance.stop
        operation.add_event!(:info, "Instance #{name} stopping.")
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
  end

  def do_sync(job = {})
    if (operation = Operation.find(job['id']))
      Powernode.logger.info "Syncing instance #{id}."
      operation.progress!(50)
      if ssh_ip_address && ssh_key && ssh_key_file
        begin
          session = Net::SSH.start(ssh_ip_address, admin_user, key_data: ssh_key, paranoid: false)
          session.exec!('sudo /usr/sbin/ipn -S')
          operation.add_event!(:info, "Instance #{name} synced.")
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
      end
    end
  end

  def do_terminate(job = {})
    if (operation = Operation.find(job['id'])) && instance
      Powernode.logger.info "Terminating instance #{id}."
      operation.progress!(50)
      begin
        self.instance.destroy
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      operation.add_event!(:info, "Instance #{name} terminated.")
    end
  end

  def instance
    begin
      @instance = compute.servers.get(entity)
      self.status = 'terminated' unless @instance
      self.save if changed?
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
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

  def identity
    <<-EOF.strip_heredoc
      ID=#{id}
      KEY=#{key}
      SERVER=#{node.proxy_url.present? ? node.proxy_url : Powernode.config(:server_url)}/api/node_v1
    EOF
  end

  def identity_parameters
    "ID=#{id} " +
    "KEY=#{key} " +
    "SERVER=#{node.proxy_url.present? ? node.proxy_url : Powernode.config(:server_url)}/api/node_v1 "
  end

  def netboot_sync
    sleep 1 until node.node_architecture.init_sync!
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
end
