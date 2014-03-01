#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'powernode'

class NodeAgent
  include Sidekiq::Worker

  Pony.options = { from: PowerNode.config(:smtp_from_email), via: :smtp,
                   via_options: { address:              PowerNode.config(:smtp_server),
                                  port:                 PowerNode.config(:smtp_port),
                                  domain:               PowerNode.config(:smtp_domain),
                                  user_name:            PowerNode.config(:smtp_user_name),
                                  password:             PowerNode.config(:smtp_password),
                                  authentication:       PowerNode.config(:smtp_authentication),
                                  enable_starttls_auto: PowerNode.config(:smtp_enable_starttls_auto) } }

  Sidekiq.configure_server do |config|
    config.redis = { namespace: PowerNode.config(:redis_namespace), url: PowerNode.config(:redis_server) }
    config.server_middleware do |chain|
      chain.add Sidekiq::Encryptor::Server, key: PowerNode.config('redis_encryption_key') if PowerNode.config('redis_encryption_key')
    end
    config.client_middleware do |chain|
      chain.add Sidekiq::Encryptor::Client, key: PowerNode.config('redis_encryption_key') if PowerNode.config('redis_encryption_key')
    end
  end

  sidekiq_options({ queue: PowerNode.config(:node_agent_queue),
                    retry: PowerNode.config(:job_retries),
                    unique: :all,
                    expiration: PowerNode.config(:node_agent_job_expiration) })

  def perform(message)
    @notifications = []
    operation = JSON.parse(message, symbolize_names: true)
    @parent_resource = RestClient::Resource.new(PowerNode.config(:node_server_url) + '/api/v1',
                                                PowerNode.config(:id),
                                                PowerNode.config(:key))
    begin
      @node = Node.new(JSON.parse(@parent_resource["node/#{operation[:node_id]}.json"].get))
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    if @node
      @cloud = configure_endpoint(@node)
      @stamp = "[#{operation[:command]}:#{@node.id}]"
      if @node.dirty?
        dirty_attributes = PowerNode.config(:encrypted_attributes).map { |a| @node.respond_to?("#{a}_dirty") ? { a.to_sym => @node.send('raw_' + a) } : nil }.compact
        begin
          @parent_resource["node/#{@node.id}.json"].post(node: dirty_attributes)
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
      end
      if @node.provider.dirty?
        dirty_attributes = PowerNode.config(:encrypted_attributes).map { |a| @node.provider.respond_to?(a) ? { a.to_sym => @node.provider.send('raw_' + a) } : nil }.compact
        begin
          @parent_resource["node/#{@node.id}/provider/#{@node.provider.id}.json"].post(provider: dirty_attributes)
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
      end
      @node.node_instances.each do |node_instance|
        if node_instance.dirty?
          dirty_attributes = PowerNode.config(:encrypted_attributes).map { |a| node_instance.respond_to?(a) ? { a.to_sym => node_instance.send('raw_' + a) } : nil }.compact
          begin
            @parent_resource["node/#{@node.id}/instance/#{node_instance.id}.json"].post(node_instance: dirty_attributes)
          rescue => e
            logger.error "#{@stamp} Exception: #{e.message}."
          end
        end
      end
      @node = Node.new(JSON.parse(@parent_resource["node/#{operation[:node_id]}.json"].get)) if @node.dirty? || @node.provider.dirty?
      send("do_#{operation[:command]}") if operation[:command] && respond_to?("do_#{operation[:command]}")
    end
  end

  def do_node_operations
    if @node.enabled && @node.operations.is_a?(Array) && @node.operations.count > 0
      @node.operations.each do |operation|
        @operation = operation
        @node_instance = @node.node_instances.select { |i| i.id == @operation.node_instance_id }.first if @operation.try(:node_instance_id)
        @node_module_id = @operation.node_module_id if @operation.try(:node_module_id)
        if (!@operation.scheduled_at || Time.parse(@operation.scheduled_at) < Time.now)
          notify_parent(@operation.id, 'running')
          send("do_#{operation.command}") if respond_to?("do_#{@operation.command}")
          notify_parent(@operation.id, 'complete')
        end
      end
    end
  end

  def do_poll_node
    do_node_operations
    logger.info "#{@stamp} Performing cloud instance check."
    logger.info "#{@stamp} Instance count variance: #{@node.instance_variance}."
    if @node.enabled
      if @node.cloud_instances.count > 0
        @node.cloud_instances.each do |node_instance|
          begin
            deregister_instance(node_instance) unless (cloud_instance = @cloud.servers.get(node_instance.name))
          rescue => e
            logger.error "#{@stamp} Exception: #{e.message}."
            deregister_instance(node_instance) if e.class == Fog::Compute::AWS::NotFound
          end
          if cloud_instance && cloud_instance.flavor_id == @node.node_instance_type.name
            logger.info "#{@stamp} Updating instance #{node_instance.id}."
            node_instance.private_ip_address = cloud_instance.private_ip_address
            node_instance.public_ip_address = cloud_instance.public_ip_address
            node_instance.state = cloud_instance.state
            @parent_resource["node/#{@node.id}/instance.json"].post({ node_instance: node_instance }.to_json,
                                                                    accept: :json,
                                                                    content_type: :json)
          elsif cloud_instance && cloud_instance.flavor_id != @node.node_instance_type.name
            logger.info "#{@stamp} Node instance type incorrect for instance: #{cloud_instance.id}."
            do_instance_terminate(node_instance)
          end
        end
      end
      if @node.instance_variance > 0
        logger.info "#{@stamp} Launching #{@node.instance_variance} instances."
        launch_instances(@node.instance_variance)
      elsif @node.instance_variance < 0
        logger.info "#{@stamp} Destroying #{@node.instance_variance.abs} instances."
        terminate_instances(@node.cloud_instances, @node.instance_variance.abs)
      end
    elsif @node.cloud_instances.count > 0
      terminate_instances(@node.cloud_instances, @node.cloud_instances.count)
    end
    logger.info "#{@stamp} Performing physical instance check."
    @node.physical_instances.each do |node_instance|
      logger.info "#{@stamp} Checking physical instance #{node_instance.name}."
      netboot_sync(node_instance)
    end
    netboot_clean
    logger.info "#{@stamp} Physical instance check complete."
  end

  def do_instance_exec(node_instance = @node_instance)
    if node_instance
      logger.info "#{@stamp} Executing (#{@command.exec}) on #{node_instance.name}."
      begin
        session = Net::SSH.start(node_instance.public_ip_address,
                                 @node.admin_user,
                                 key_data: @node.ssh_key)
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
      begin
        session.exec!("sudo #{@command.exec}") if session
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
    end
  end

  def do_instance_public_ip_associate(node_instance = @node_instance)
    if node_instance
      logger.info "#{@stamp} Associating floating IP for instance #{node_instance.name}."
      begin
        cloud_instance = @cloud.servers.get(node_instance.name)
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
      begin
        address = @cloud.addresses.find { |ip| ip.server_id.nil? }
        address ||= @cloud.addresses.create
        address.server = cloud_instance if address
        @notifications << Notification.new({ notice: "Associated IP #{address.public_ip} for instance #{node_instance.name}." })
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
    end
  end

  def do_instance_public_ip_disassociate(node_instance = @node_instance)
    if node_instance
      begin
        if (address = @cloud.addresses.find { |ip| ip.server_id =~ /#{node_instance.name}/ })
          logger.info "#{@stamp} Disassociating floating IP for instance #{node_instance.name}."
          address.server = nil
          address.destroy
          @notifications << Notification.new({ notice: "Disassociated IP #{address.public_ip} from instance #{node_instance.name}." })
        end
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
    end
  end

  def do_instance_reboot(node_instance = @node_instance)
    if node_instance
      logger.info "#{@stamp} Rebooting instance #{node_instance.id}."
      begin
        @cloud.reboot_instances(node_instance.name)
        @notifications << Notification.new({ notice: "Instance #{node_instance.name} rebooted." })
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
    end
  end

  def do_instance_start(node_instance = @node_instance)
    if node_instance
      logger.info "#{@stamp} Starting instance #{node_instance.id}."
      begin
        @cloud.start_instances(node_instance.name)
        @notifications << Notification.new({ notice: "Instance #{node_instance.name} started." })
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
    end
  end

  def do_instance_stop(node_instance = @node_instance)
    if node_instance
      logger.info "#{@stamp} Stopping instance #{node_instance.name}."
      begin
        @cloud.stop_instances(node_instance.name)
        @notifications << Notification.new({ notice: "Instance #{node_instance.name} stopped." })
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
    end
  end

  def do_instance_terminate(node_instance = @node_instance)
    if node_instance
      do_instance_public_ip_disassociate(node_instance)
      terminate_instance(node_instance)
      @notifications << Notification.new({ notice: "Instance #{node_instance.name} terminated." })
    end
  end

  def do_create_iso(node_instance = @node_instance)
    init_sync
    init_dir = PowerNode.config(:init_dir)
    logger.info "#{@stamp} Creating ISO for node #{@node.id}."
    begin
      FileUtils.mkdir_p(init_dir) unless Dir.exist?(init_dir)
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    begin
      tmp_dir = Dir.mktmpdir
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    begin
      FileUtils.cp(File.join(init_dir, 'isolinux.bin'), File.join(tmp_dir))
      FileUtils.cp(File.join(init_dir, "#{@node.node_architecture.id}.kernel"), File.join(tmp_dir, 'kernel'))
      FileUtils.cp(File.join(init_dir, "#{@node.node_architecture.id}.ramdisk"), File.join(tmp_dir, 'ramdisk'))
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    begin
      FileUtils.mkdir_p(File.join(tmp_dir, @node.store_dir))
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    begin
      node_modules = JSON.parse(@parent_resource["node/#{@node.id}/modules.json?provisional=true"].get).map { |m| NodeModule.new(m) }
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    if node_modules
      node_modules.each do |node_module|
        module_file_name = "#{node_module.id}-#{node_module.data_file_version}.#{@node.module_extension}"
        module_file = File.join(tmp_dir, @node.store_dir, module_file_name)
        begin
          File.open(module_file, File::RDWR|File::CREAT, 0644) do |f|
            f.flock(File::LOCK_EX)
            f << @parent_resource["node/#{@node.id}/module/#{node_module.id}.html"].get
          end
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
        module_info_file_name = "#{node_module.id}-#{node_module.data_file_version}.#{@node.module_info_extension}"
        module_info = File.join(tmp_dir, @node.store_dir, module_info_file_name)
        begin
          File.open(module_info, File::RDWR|File::CREAT, 0644) do |f|
            f.flock(File::LOCK_EX)
            f << @parent_resource["node/#{@node.id}/module/#{node_module.id}/config.text"].get
          end
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
      end
    end
    node_cfg_file = File.join(tmp_dir, 'node.cfg')
    begin
      File.open(node_cfg_file, File::RDWR|File::CREAT, 0644) do |f|
        f.flock(File::LOCK_EX)
        f.puts(node_instance.config)
      end
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    volume_cfg_file = File.join(tmp_dir, 'volume.cfg')
    begin
      File.open(volume_cfg_file, File::RDWR|File::CREAT, 0644) do |f|
        f.flock(File::LOCK_EX)
        f.puts("STORE=#{@node.store_dir}")
      end
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    FileUtils.mkdir_p(File.join(tmp_dir, 'syslinux'))
    syslinux_cfg_file = File.join(tmp_dir, 'syslinux', 'syslinux.cfg')
    begin
      File.open(syslinux_cfg_file, File::RDWR|File::CREAT, 0644) do |f|
        f.flock(File::LOCK_EX)
        f << "DEFAULT alchemy\n" +
             "LABEL alchemy\n" +
             "LINUX /kernel\n" +
             "INITRD /ramdisk\n" +
             "APPEND HOSTNAME=#{node_instance.name} " +
             "PARENT=#{PowerNode.config(:node_proxy_url).nil? ? PowerNode.config(:node_server_url) : PowerNode.config(:node_proxy_url)} " +
             "ID=#{node_instance ? node_instance.id : @node.id} " +
             "KEY=#{node_instance.agent_key.blank? ? @node.agent_key : node_instance.agent_key } "
        if node_instance.private_ip_static
          f << "ip=#{node_instance.private_ip_address}:" +
               ":" +
               "#{node_instance.private_ip_gateway}:" +
               "#{node_instance.private_ip_netmask}:" +
               "#{node_instance.name}:" +
               "#{node_instance.private_ip_device}:" +
               "off " +
               "DNS_PRIMARY=#{node_instance.private_ip_primary_dns} " +
               "DNS_SECONDARY=#{node_instance.private_ip_secondary_dns} " +
               "DNS_DOMAIN=#{node_instance.private_ip_domain}\n"
        else
          f << "\n"
        end
      end
    end
    begin
      system("sudo chown -R root:root #{tmp_dir}")
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    node_iso_file = Tempfile.new("#{@node.id}.iso-")
    FileUtils.chmod(0644, node_iso_file)
    system("sudo mkisofs -o #{node_iso_file.path} -b isolinux.bin -c syslinux/boot.cat -R -J -l -relaxed-filenames -no-emul-boot -boot-load-size 4 -boot-info-table #{tmp_dir} > /dev/null 2>&1")
    if node_iso_file.size > 0
      begin
        @parent_resource["node/#{@node.id}/iso.html"].post(
          node_instance_id: node_instance.id,
          iso: File.open(node_iso_file),
          multipart: true,
          content_type: 'application/octet-stream')
        logger.info "#{@stamp} ISO created for instance #{node_instance.id}."
        @notifications << Notification.new({ notice: "ISO created for instance #{node_instance.name}" })
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
    end
    FileUtils.remove_entry_secure(tmp_dir)
  end

  def do_node_module_build
    notification = Notification.new
    node_module = NodeModule.new(JSON.parse(@parent_resource["node/#{@node.id}/module/#{@node_module_id}.json"].get))
    if @node.primary_instance && !node_module.package_spec.empty?
      logger.info "#{@stamp} Building module #{node_module.id}."
      packages = node_module.package_spec.map { |p| Base64.decode64(p) }
      begin
        session = Net::SSH.start(@node.primary_instance.public_ip_address,
                                 @node.admin_user,
                                 key_data: @node.ssh_key)
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
        notification.error ||= "Error connecting to instance #{@node.primary_instance}\n#{e.message}"
      end
      if session
        begin
          response = session.verbose_exec!("sudo ipn -e #{node_module.build_script_id} #{node_module.id} /tmp/#{node_module.id}.spec")
          output = response[:stdout]
          error = response[:stderr]
          exit_code = response[:exit_code]
          if exit_code != 0
            notification.warning ||= "Error installing packages for module #{node_module.name}\n#{output}"
            notification.error ||= error
          end
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
          notification.error ||= "Error installing packages for module #{node_module.name}\n#{e.message}"
        end
        if exit_code == 0
          logger.info "#{@stamp} Uploading spec for module #{node_module.id}."
          begin
            spec = session.exec!("cat /tmp/#{node_module.id}.spec")
            @parent_resource["node/#{@node.id}/module/#{node_module.id}.json"].post({ spec: spec }, accept: :json)
            notification.notice ||= "Successfully built module #{node_module.name}"
          rescue => e
            logger.error "#{@stamp} Exception: #{e.message}."
          end
        end
      end
    end
    @notifications << notification if notification.keys.size > 0
  end

  def do_node_module_commit
    node_module = NodeModule.new(JSON.parse(@parent_resource["node/#{@node.id}/module/#{@node_module_id}.json"].get))
    logger.info "#{@stamp} Committing module #{node_module.id}."
    if @node.primary_instance && !node_module.effective_spec.empty?
      tmp_dir = Dir.mktmpdir
      FileUtils.chmod(0755, tmp_dir)
      begin
        tmp_spec = Tempfile.new("spec-#{@node.id}-#{node_module.id}")
        File.open(tmp_spec, File::RDWR|File::CREAT, 0644) do |f|
          f.flock(File::LOCK_EX)
          node_module.effective_spec.each do |l|
            f.write(Base64.decode64(l) + "\n")
          end
        end
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
        FileUtils.remove_entry_secure(tmp_dir, force: true)
      end
      if File.directory?(tmp_dir)
        begin
          system("sudo rsync -lptgoDH -e \"ssh -q -p #{PowerNode.config(:ssh_port)} -o StrictHostKeyChecking=no -i #{@node.ssh_key_file}\" " +
                 "--files-from=#{tmp_spec.path} #{@node.admin_user}@#{@node.primary_instance.public_ip_address}:/ #{tmp_dir}/ > /dev/null 2>&1")
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
        case $?.exitstatus
        when 23
          logger.warn "#{@stamp} Not all files transferred."
          @notifications << Notification.new({ warning: "Not all files transferred for module #{node_module.name}" })
        when 255
          logger.error "#{@stamp} Unable to connect."
          @notifications << Notification.new({ error: "Unable to connect to instance #{@node.primary_instance.name}" })
          FileUtils.remove_entry_secure(tmp_dir, force: true)
        end
      end
      if File.directory?(tmp_dir)
        tmp_module = Tempfile.new("module-#{@node.id}-#{node_module.id}")
        tmp_module.close
        begin
          system("sudo mksquashfs #{tmp_dir} #{tmp_module.path} -comp #{PowerNode.config(:module_compression)} -noappend -no-progress > /dev/null 2>&1")
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
        if tmp_module.size > 0
          begin
            @parent_resource["node/#{@node.id}/module/#{node_module.id}.html"].post(
              data: File.open(tmp_module),
              multipart: true,
              content_type: 'application/octet-stream')
          rescue => e
            logger.error "#{@stamp} Exception: #{e.message}."
          end
          FileUtils.remove_entry_secure(tmp_module, force: true)
          FileUtils.remove_entry_secure(tmp_dir, force: true)
          logger.info "#{@stamp} Commit complete for module #{node_module.id}."
          @notifications << Notification.new({ notice: "Commit complete for module #{node_module.name}" })
        else
          logger.error "#{@stamp} Commit aborted."
        end
      else
        logger.error "#{@stamp} Commit aborted."
      end
    elsif @node.primary_instance.nil?
      logger.info "#{@stamp} Commit aborted: No primary instance found."
      @notifications << Notification.new({ error: "Commit aborted: No primary instance found" })
    else
      logger.info "#{@stamp} Commit aborted: No module specification."
      @notifications << Notification.new({ error: "Commit aborted: No module specification" })
    end
  end

  def do_send_ssh_key
    recipient = @operation.recipient
    encryption_key = @operation.encryption_key
    logger.info "#{@stamp} Sending SSH key to #{recipient}."
    if @node.ssh_key && encryption_key && encryption_key.is_a?(String) && encryption_key.length == PowerNode.config(:encryption_key_length)
      encryption_key = [encryption_key].pack('H*')
      cipher = OpenSSL::Cipher.new(PowerNode.config(:encryption_cipher))
      cipher.encrypt
      cipher.key = encryption_key
      iv = cipher.random_iv
      encrypted_ssh_key = Base64.encode64(cipher.update(@node.ssh_key) + cipher.final)
    else
      encrypted_ssh_key = @node.ssh_key
    end
    if @node.ssh_key
      body = <<-EOF.strip_heredoc
        Attached is the encrypted SSH key for node #{@node.name}.

        You must decrypt the ssh key with the following command:
        $ openssl #{PowerNode.config(:encryption_cipher)} -base64 -d -in #{@node.name}.txt -out #{@node.name}.pem -iv #{iv.unpack('H*')[0]} -K [encryption key]

        Change the file permissions:
        $ chmod 600 #{@node.name}.pem

        SSH in to an instance by specifying the private key:
        $ ssh -i #{@node.name}.pem #{@node.admin_user}@[ip address]

        Thanks,
        Node Alchemy
      EOF
      begin
        Pony.mail(to: recipient,
                  subject: "SSH key for #{@node.name}",
                  body: body,
                  attachments: { "#{@node.name}.txt" => encrypted_ssh_key })
        @notifications << Notification.new({ notice: "SSH key for #{@node.name} delivered to #{recipient}" })
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
    else
      @notifications << Notification.new({ error: "SSH key not found for node #{@node.name}" })
    end
  end

  def do_update_cloud_instances
    @node.cloud_instances.each do |node_instance|
      logger.info "#{@stamp} Updating instance: #{node_instance.name}."
      if node_instance.public_ip_address && @node.ssh_key
        begin
          session = Net::SSH.start(node_instance.public_ip_address,
                                   @node.admin_user,
                                   key_data: @node.ssh_key)
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
        begin
          session.exec!('sudo /usr/sbin/ipn -u')
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
      end
      @parent_resource["node/#{@node.id}/instance.json"].post({ node_instance: node_instance }.to_json, accept: :json, content_type: :json)
    end
    @notifications << Notification.new({ notice: "Node instance update complete." })
  end

  private

  def configure_endpoint(node = @node)
    endpoint_type = @node.provider_endpoint.endpoint_type
    provider = { provider: endpoint_type,
                 endpoint: @node.provider_endpoint.endpoint_url }
    case endpoint_type
    when 'aws'
      provider[:aws_access_key_id] = @node.provider.access_key
      provider[:aws_secret_access_key] = @node.provider.secret_key
    end
    begin
      endpoint = Fog::Compute.new(provider)
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    endpoint
  end

  def deregister_instance(node_instance = @node_instance)
    logger.info "#{@stamp} Deregistering instance #{node_instance.name}."
    @parent_resource["node/#{@node.id}/instance/#{node_instance.id}.json"].delete
    @node.node_instances.delete_if { |i| i.id == node_instance.id }
  end

  def get_key
    keypair_name = @node.id
    keys = []
    begin
      logger.info "#{@stamp} Retrieving keypairs."
      keys = @cloud.key_pairs.all
      key = keys.select { |k| k.name == keypair_name }.first
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
    end
    if key && key.fingerprint == @node.ssh_key_fingerprint
      logger.info "#{@stamp} Found valid key: #{keypair_name}."
    else
      begin
        logger.info "#{@stamp} Deleting key: #{keypair_name}."
        @cloud.delete_key_pair(keypair_name)
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
      begin
        logger.info "#{@stamp} Creating key: #{keypair_name}."
        key = @cloud.key_pairs.create(name: keypair_name)
      rescue => e
        logger.error "#{@stamp} Exception: #{e.message}."
      end
      if key && key.private_key
        node_attributes = { ssh_key: key.private_key, ssh_key_fingerprint: key.fingerprint }
        logger.info "#{@stamp} Uploading new keypair #{keypair_name} to parent."
        if @parent_resource["node/#{@node.id}"].post(node: node_attributes)
          if (ssh_key_dir = PowerNode.config(:ssh_key_dir))
            FileUtils.mkdir_p(ssh_key_dir)
            FileUtils.touch(@node.ssh_key_file)
            FileUtils.chmod(0600, @node.ssh_key_file)
            File.open(@node.ssh_key_file, File::RDWR|File::CREAT, 0644) do |f|
              f.flock(File::LOCK_EX)
              f.write(key.private_key)
            end
          end
        end
      end
    end
    key
  end

  def init_sync
    init_dir = PowerNode.config(:init_dir)
    FileUtils.mkdir_p(init_dir)
    %w[kernel ramdisk].each do |component|
      init_file = File.join(init_dir, "#{@node.node_architecture.id}.#{component}")
      component_checksum = @node.node_architecture.send("#{component}_checksum")
      if component_checksum.present? && (!File.exists?(init_file) || component_checksum != Digest::SHA2.new(PowerNode.config(:checksum_bitlength)).hexdigest(File.binread(init_file)))
        logger.info "#{@stamp} Downloading #{component} for architecture #{@node.node_architecture.id}."
        begin
          File.open(init_file, File::RDWR|File::CREAT, 0644) do |f|
            f.flock(File::LOCK_EX)
            f.write(@parent_resource["node/#{@node.id}/architecture/#{component}.html"].get)
          end
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
      end
    end
  end

  def launch_instances(count = 1)
    if (key = get_key)
      count.times do
        instance_options = {}
        instance_options[:availability_zone] = @node.provider_endpoint.availability_zone if @node.provider_endpoint.availability_zone
        instance_options[:image_id] = @node.provider_endpoint.machine_image if !@node.provider_endpoint.machine_image.empty?
        instance_options[:kernel_id] = @node.provider_endpoint.kernel_image if !@node.provider_endpoint.kernel_image.empty?
        instance_options[:ramdisk_id] = @node.provider_endpoint.ramdisk_image if !@node.provider_endpoint.ramdisk_image.empty?
        instance_options[:flavor_id] = @node.node_instance_type.name
        instance_options[:region] = @node.provider_endpoint.region
        instance_options[:key_name] = key.name
        instance_options[:user_data] = node_credentials
        begin
          cloud_instance = @cloud.servers.create(instance_options)
          sleep 10
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
        if cloud_instance
          node_instance = NodeInstance.new({ name: cloud_instance.id,
                                             cloud: true,
                                             private_ip_address: cloud_instance.private_ip_address,
                                             public_ip_address: cloud_instance.public_ip_address,
                                             state: cloud_instance.state,
                                             started_at: cloud_instance.created_at })
          begin
            @parent_resource["node/#{@node.id}/instance.json"].post({ node_instance: node_instance }.to_json, accept: :json, content_type: :json)
            logger.info "#{@stamp} Created new instance: #{cloud_instance.id}."
          rescue => e
            @cloud.servers.destroy(cloud_instance.id)
            logger.error "#{@stamp} Exception: #{e.message}."
          end
          do_instance_public_ip_associate(node_instance)
        end
      end
    end
  end

  def logger
    if @logger.nil?
      @logger = Logger.new(File.join(PowerNode.config(:log_dir), PowerNode.config(:node_agent_logfile)), PowerNode.config(:log_cycle))
      @logger.level = Logger.const_get(PowerNode.config(:node_agent_loglevel).upcase)
    end
    @logger
  end

  def node_credentials
    <<-EOF.strip_heredoc
      ID=#{@node_instance ? @node_instance.id : @node.id}
      KEY=#{(@node_instance && !@node_instance.agent_key.blank?) ? @node_instance.agent_key : @node.agent_key}
      PARENT=#{PowerNode.config(:node_proxy_url).nil? ? PowerNode.config(:node_server_url) : PowerNode.config(:node_proxy_url)}
      INIT_SCRIPT=#{@node.init_script_id}
    EOF
  end

  def netboot_clean
    pxelinux_dir = File.join(PowerNode.config(:init_dir), 'pxelinux.cfg')
    Dir.glob(File.join(pxelinux_dir, '??-??-??-??-??-??')) do |f|
      FileUtils.rm(f) if File.mtime(f) < Time.now - PowerNode.config(:init_expire)
    end
  end

  def netboot_sync(node_instance = @node_instance)
    init_sync
    init_dir = PowerNode.config(:init_dir)
    pxelinux_dir = File.join(init_dir, 'pxelinux.cfg')
    FileUtils.mkdir_p(pxelinux_dir) unless Dir.exist?(pxelinux_dir)
    if node_instance.private_netboot_enabled && !node_instance.private_mac_address.empty?
      logger.info "#{@stamp} Synchronizing netboot config for instance #{node_instance.id}."
      netboot_cfg_file = File.join(pxelinux_dir, node_instance.private_mac_address)
      if File.exist?(netboot_cfg_file)
        updated_at = open(netboot_cfg_file, 'r') { |f| f.each_line.find { |line| line.include?('Updated:') }.try(:match, /(\d\d\d\d)-(\d\d)-(\d\d)T(.*)-(\d\d):(\d\d)/) }
      end
      if File.exist?(netboot_cfg_file) && (File.mtime(netboot_cfg_file) < Time.now - PowerNode.config(:init_expire) || node_instance.updated_at == updated_at)
        FileUtils.touch(netboot_cfg_file)
      else
        kernel_file_name = "#{@node.node_architecture.id}.kernel"
        ramdisk_file_name = "#{@node.node_architecture.id}.ramdisk"
        begin
          File.open(netboot_cfg_file, File::RDWR|File::CREAT, 0644) do |f|
            f.flock(File::LOCK_EX)
            f << "# Updated: #{node_instance.updated_at}\n" +
                 "DEFAULT alchemy\n" +
                 "LABEL alchemy\n" +
                 "LINUX /#{kernel_file_name}\n" +
                 "INITRD /#{ramdisk_file_name}\n" +
                 "APPEND HOSTNAME=#{node_instance.name} " +
                 "PARENT=#{PowerNode.config(:node_proxy_url).nil? ? PowerNode.config(:node_server_url) : PowerNode.config(:node_proxy_url)} " +
                 "ID=#{node_instance ? node_instance.id : @node.id} " +
                 "KEY=#{node_instance.agent_key.blank? ? @node.agent_key : node_instance.agent_key } "
            if node_instance.private_ip_static
              f << "ip=" +
                   "#{node_instance.private_ip_address}:" +
                   ":" +
                   "#{node_instance.private_ip_gateway}:" +
                   "#{node_instance.private_ip_netmask}:" +
                   "#{node_instance.name}:" +
                   "#{node_instance.private_ip_device}:" +
                   "off " +
                   "DNS_PRIMARY=#{node_instance.private_ip_primary_dns} " +
                   "DNS_SECONDARY=#{node_instance.private_ip_secondary_dns} " +
                   "DNS_DOMAIN=#{node_instance.private_ip_domain}\n"
            else
              f << "\n"
            end
          end
        rescue => e
          logger.error "#{@stamp} Exception: #{e.message}."
        end
      end
    end
  end

  def notify_parent(operation_id, status)
    @parent_resource['node']["#{@node.id}.json"].post({ operation_id: operation_id,
                                                        status: status,
                                                        notifications: @notifications }.to_json,
                                                      accept: :json, content_type: :json)
    @notifications = []
  end

  def terminate_instance(node_instance)
    logger.info "#{@stamp} Destroying instance: #{node_instance.name}."
    begin
      @cloud.servers.destroy(node_instance.name)
      do_instance_public_ip_disassociate(node_instance)
      deregister_instance(node_instance)
    rescue => e
      logger.error "#{@stamp} Exception: #{e.message}."
      deregister_instance(node_instance) if e.class == Fog::Compute::AWS::NotFound
    end
  end

  def terminate_instances(node_instances, count)
    count.times do |n|
      node_instance = node_instances.reverse[n]
      terminate_instance(node_instance)
    end
  end
end
