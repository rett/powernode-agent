class Node
  include Her::Model

  belongs_to :account
  belongs_to :node_platform
  belongs_to :node_template
  has_many :node_instances
  has_many :node_modules
  has_many :operations
  has_many :provider_volumes

  delegate :node_architecture, to: :node_template

  parse_root_in_json true

  def cloud_instances
    node_instances.where(variety: 'cloud')
  end

  def dynamic_instances
    node_instances.where(variety: 'dynamic')
  end

  def physical_instances
    node_instances.where(variety: 'physical')
  end

  def primary_instance
    node_instances.find(primary_instance_id)
  end

  def do_maintenance(job = {})
    if enabled?
      command = 'maintenance'
      node_instances.each do |node_instance|
        if Agent.perform_async({ command: command, operable_type: 'node_instance', operable_id: node_instance.id })
          Powernode.logger.info "Queued #{command} for node instance #{node_instance.id}."
        end
      end
    elsif dynamic_instances.count > 0
      terminate_dynamic_instances!(dynamic_instances.count)
    end
  end

  def do_create_cloud_instance(job = {})
    options = job['options']
    if options.is_a?(Hash)
      provider_connection_id      = options['provider_connection_id']
      provider_availability_zone  = options['provider_availability_zone']
      provider_region_id          = options['provider_region_id']
      provider_instance_type_id   = options['provider_instance_type_id']
      provider_network_subnet_id  = options['provider_network_subnet_id']
      variety                     = options['variety']
      provider_connection = account.provider_connections.find(provider_connection_id) if provider_connection_id
      provider_region = account.provider_regions.find(provider_region_id) if provider_region_id
      provider_instance_type = provider_region.provider_instance_types.find(provider_instance_type_id) if provider_region && provider_instance_type_id
      provider_network_subnet = provider_region.provider_network_subnets.find(provider_network_subnet_id) if provider_region
      node_instance = nil
      if node_instances.count < instance_limit && ssh_key_data
        Powernode.logger.info "Launching new instance for node #{id}."
        node_instance = NodeInstance.new(id: UUIDTools::UUID.timestamp_create, node_id: id)
        node_instance.provider_connection_id = provider_connection.id
        node_instance.provider_region_id = provider_region.id
        node_instance.key = SecureRandom.urlsafe_base64(Powernode.config(:instance_key_length))
        node_instance.availability_zone = provider_availability_zone
        node_instance.provider_instance_type_id = provider_instance_type_id
        node_instance.variety = variety
        case provider_connection.variety
        when 'openstack'
          begin
            flavor = provider_connection.compute(provider_region).flavors.find { |f| f.name == provider_instance_type.name }.try(:id)
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
        else
          flavor = provider_instance_type.name
        end
        instance_options = {}
        instance_options[:name]               = node_instance.id
        instance_options[:user_data]          = node_instance.identity
        instance_options[:availability_zone]  = provider_availability_zone      if provider_availability_zone.present?
        instance_options[:image_id]           = provider_region.machine_image   if provider_region.machine_image.present?
        instance_options[:image_ref]          = provider_region.machine_image   if provider_region.machine_image.present?
        instance_options[:kernel_id]          = provider_region.kernel_image    if provider_region.kernel_image.present?
        instance_options[:ramdisk_id]         = provider_region.ramdisk_image   if provider_region.ramdisk_image.present?
        instance_options[:region]             = provider_region.region          if provider_region.region.present?
        instance_options[:subnet_id]          = provider_network_subnet.entity  if provider_network_subnet.present?
        instance_options[:flavor_id]          = flavor
        instance_options[:flavor_ref]         = flavor
        begin
          cloud_instance = provider_connection.compute(provider_region).servers.create(instance_options)
          cloud_instance.wait_for { state != 'pending' }
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        if cloud_instance
          node_instance.entity = cloud_instance.id
          node_instance.name = cloud_instance.id
          node_instance.private_ip_address = cloud_instance.private_ip_address
          node_instance.status = cloud_instance.state.downcase
          node_instance.started_at = cloud_instance.respond_to?(:created_at) ? cloud_instance.created_at : cloud_instance.created
          if node_instance.save
            begin
              node_instance.do_public_ip_associate(job) if allocate_public_ip?
              Powernode.logger.info "Launched instance #{cloud_instance.id}."
            rescue => e
              Powernode.logger.error "Exception: #{e.message}."
            end
          else
            begin
              provider.compute.servers.destroy(cloud_instance.id)
            rescue => e
              Powernode.logger.error "Exception: #{e.message}."
            end
            node_instance = nil
          end
        end
      else
        Powernode.logger.info 'Account instance limit exceeded, refusing to create instance.'
      end
      if node_instance && node_instance.variety == 'cloud'
        account.notifications.create(category: :notice, summary: "Successfully created cloud instance #{node_instance.name}.")
      elsif node_instance.nil?
        account.notifications.create(category: :error, summary: 'Failed to create new instance!')
      end
    end
  end

  def do_send_ssh_key(job = {})
    options = job['options']
    if options.is_a?(Hash)
      recipient = options['recipient']
      encryption_key = options['ssh_encryption_key']
      Powernode.logger.info "Sending SSH key to #{recipient}."
      if ssh_key && encryption_key && encryption_key.is_a?(String) && encryption_key.length == Powernode.config(:encryption_key_length)
        encryption_key = [encryption_key].pack('H*')
        cipher = OpenSSL::Cipher.new(Powernode.config(:encryption_cipher))
        cipher.encrypt
        cipher.key = encryption_key
        iv = cipher.random_iv
        encrypted_ssh_key = Base64.encode64(cipher.update(ssh_key) + cipher.final)
      else
        encrypted_ssh_key = ssh_key
      end
      if ssh_key
        body = <<-EOF.strip_heredoc
          Attached is the encrypted SSH key for node #{name}.

          You must decrypt the ssh key with the following command:
          $ openssl #{Powernode.config(:encryption_cipher)} -base64 -d -in "#{name}.txt" -out "#{name}.pem" -iv #{iv.unpack('H*')[0]} -K [encryption key]

          Change the file permissions:
          $ chmod 600 #{name}.pem

          SSH in to an instance by specifying the private key:
          $ ssh -i #{name}.pem #{admin_user}@[ip address]

          Thanks,
          Node Alchemy
        EOF
        begin
          Pony.mail(to: recipient,
                    subject: "SSH key for #{name}",
                    body: body,
                    attachments: { "#{name}.txt" => encrypted_ssh_key })
          account.notifications.create(category: :notice, summary: "SSH key for #{name} delivered to #{recipient}")
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
      else
        account.notifications.create(category: :alert, summary: "SSH key not found for node #{name}")
      end
    end
  end

  def do_sync_cloud_instances(job = {})
    command = 'sync'
    (cloud_instances + dynamic_instances).each do |node_instance|
      if Agent.perform_async({ command: command, operable_type: 'node_instance', operable_id: node_instance.id })
        Powernode.logger.info "Queued #{command} for node instance #{node_instance.id}."
      end
    end
  end

  def ssh_key_data
    unless @ssh_key_data
      if ssh_key.present?
        @ssh_key_data = OpenSSL::PKey::RSA.new(ssh_key)
      else
        @ssh_key_data = OpenSSL::PKey::RSA.new(2048)
      end
      if @ssh_key_data.fingerprint != ssh_key_fingerprint
        self.ssh_key = @ssh_key_data.to_pem
        self.ssh_key_fingerprint = @ssh_key_data.fingerprint
        self.save
      end
    end
    @ssh_key_data
  end

  def ssh_key_file
    FileUtils.mkdir_p(Powernode.config(:ssh_key_dir)) unless Dir.exist?(Powernode.config(:ssh_key_dir))
    key_file = File.join(Powernode.config(:ssh_key_dir), "#{id}.pem")
    File.open(key_file, File::RDWR|File::CREAT, 0600) do |f|
      f.flock(File::LOCK_EX)
      f.write(ssh_key_data.to_pem)
      f.flush
      f.truncate(f.pos)
    end
    key_file
  end

  private

  def create_instances!(variety, count)
    command = 'create_instance'
    running_jobs = []
    count.times do
      if running_jobs << Agent.perform_async({ command: command, operable_type: 'node', operable_id: id, options: { 'variety' => variety }, unique: UUIDTools::UUID.timestamp_create })
        Powernode.logger.info "Queued #{command} for node #{id}."
      end
    end
    while running_jobs.size > 0
      running_jobs.each do |running_job|
        status = Sidekiq::Status::status(running_job)
        running_jobs.delete(running_job) if [:complete, :failed, nil].include?(status)
        sleep 1
      end
    end
  end
end
