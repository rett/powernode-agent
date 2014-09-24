class Node
  include Her::Model
  include Powernode::Encryption

  belongs_to :account
  belongs_to :node_platform
  belongs_to :node_template
  belongs_to :provider
  belongs_to :provider_instance_type
  belongs_to :provider_network_subnet
  has_many :node_instances
  has_many :node_modules
  has_many :operations
  has_many :provider_volumes

  delegate :node_architecture, to: :node_template
  delegate :provider_endpoint, to: :provider
  delegate :provider_network, to: :provider_network_subnet

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

  def do_maintenance(job)
    if enabled?
      if dynamic_instance_variance > 0
        count = dynamic_instance_variance
        if node_instances.count + count > instance_limit
          count = instance_limit - node_instances.count
          Powernode.logger.info "Account instance limit exceeded, reducing count to #{count} instances."
          self.dynamic_instance_count = dynamic_instance_max_available
          self.save
          account.notifications.create(category: :warning, summary: "Instance limit for node #{name} exceeded, reduced dynamic instance count to #{dynamic_instance_count}.")
        end
        launch_instances!('dynamic', count)
      elsif dynamic_instance_variance < 0
        terminate_dynamic_instances!(dynamic_instance_variance.abs)
      end
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

  def do_launch_instance(job)
    variety = job['options']['variety'] if job['options']
    variety ||= 'cloud'
    if node_instances.count < instance_limit
      Powernode.logger.info "Launching new instance for node #{id}."
      node_instance = NodeInstance.new(id: UUIDTools::UUID.timestamp_create, node_id: id)
      node_instance.agent_key = SecureRandom.urlsafe_base64(Powernode.config(:instance_key_length))
      node_instance.key = node_instance.agent_key
      node_instance.provider_instance_type_id = provider_instance_type.id
      node_instance.variety = variety
      case provider.endpoint_type
      when 'openstack'
        flavor = provider.compute.flavors.find { |f| f.name == provider_instance_type.name }.id
      else
        flavor = provider_instance_type.name
      end
      instance_options = {}
      instance_options[:name]               = node_instance.id
      instance_options[:user_data]          = node_instance.identity
      instance_options[:allocate_public_ip] = allocate_public_ip
      instance_options[:availability_zone]  = provider.availability_zone      if provider.availability_zone.present?
      instance_options[:image_id]           = provider.machine_image          if provider.machine_image.present?
      instance_options[:image_ref]          = provider.machine_image          if provider.machine_image.present?
      instance_options[:kernel_id]          = provider.kernel_image           if provider.kernel_image.present?
      instance_options[:ramdisk_id]         = provider.ramdisk_image          if provider.ramdisk_image.present?
      instance_options[:region]             = provider.region                 if provider.region.present?
      instance_options[:subnet_id]          = provider_network_subnet.entity  if provider_network_subnet.present?
      instance_options[:vpc_id]             = provider_network.entity         if provider_network_subnet.present?
      instance_options[:flavor_id]          = flavor
      instance_options[:flavor_ref]         = flavor
      instance_options[:key_name]           = key.name
      begin
        cloud_instance = provider.compute.servers.create(instance_options)
        cloud_instance.wait_for { state != 'pending' }
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      if cloud_instance
        node_instance.entity = cloud_instance.id
        node_instance.name = cloud_instance.id
        node_instance.provider_id = provider.id
        node_instance.private_ip_address = cloud_instance.private_ip_address
        node_instance.public_ip_address = cloud_instance.public_ip_address
        node_instance.status = cloud_instance.state
        node_instance.started_at = cloud_instance.respond_to?(:created_at) ? cloud_instance.created_at : cloud_instance.created
        if node_instance.save
          Powernode.logger.info "Launched instance #{cloud_instance.id}."
        else
          provider.compute.servers.destroy(cloud_instance.id)
          node_instance = nil
        end
      else
        node_instance = nil
      end
    else
      Powernode.logger.info 'Account instance limit exceeded, refusing to launch instance.'
      node_instance = nil
    end
    if node_instance && node_instance.variety == 'cloud'
      account.notifications.create(category: :notice, summary: "Successfully launched cloud instance #{node_instance.name}.")
    elsif node_instance.nil?
      account.notifications.create(category: :error, summary: 'Failed to launch new instance!')
    end
  end

  def do_send_ssh_key(job)
    recipient = job['options']['recipient']
    encryption_key = job['options']['ssh_encryption_key']
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

  def do_sync_cloud_instances(job)
    command = 'sync'
    (cloud_instances + dynamic_instances).each do |node_instance|
      if Agent.perform_async({ command: command, operable_type: 'node_instance', operable_id: node_instance.id })
        Powernode.logger.info "Queued #{command} for node instance #{node_instance.id}."
      end
    end
  end

  def dynamic_instance_variance
    if dynamic_instance_max_available < dynamic_instances.count
      dynamic_instance_max_available - dynamic_instances.count
    else
      dynamic_instance_count - dynamic_instances.count
    end
  end

  def key
    unless @key
      begin
        Powernode.logger.info "Retrieving keypairs for node #{id}."
        @key = provider.compute.key_pairs.all.select { |k| k.name == id }.first
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      if @key && @key.fingerprint == ssh_key_fingerprint && ssh_key_file
        Powernode.logger.info "Found valid key for node #{id}."
      else
        if @key
          Powernode.logger.info "Destroying invalid key for node #{id}."
          begin
            @key.destroy
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
        end
        Powernode.logger.info "Creating new key for node #{id}."
        begin
          @key = provider.compute.key_pairs.create(name: id)
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        if @key && @key.private_key
          Powernode.logger.info "Uploading new keypair for node #{id}."
          self.ssh_key = @key.private_key
          self.ssh_key_fingerprint = @key.fingerprint
          self.save
        end
      end
    end
    @key
  end

  def ssh_key_file
    FileUtils.mkdir_p(Powernode.config(:ssh_key_dir)) unless Dir.exist?(Powernode.config(:ssh_key_dir))
    key_file = File.join(Powernode.config(:ssh_key_dir), "#{id}.pem")
    File.open(key_file, File::RDWR|File::CREAT, 0600) do |f|
      f.flock(File::LOCK_EX)
      f.write(ssh_key)
      f.flush
      f.truncate(f.pos)
    end
    key_file
  end

  private

  def launch_instances!(variety, count)
    command = 'launch_instance'
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

  def terminate_dynamic_instances!(count)
    command = 'terminate'
    running_jobs = []
    dynamic_instances.last(count).each do |node_instance|
      if running_jobs << Agent.perform_async({ command: command, operable_type: 'node_instance', operable_id: node_instance.id, unique: UUIDTools::UUID.timestamp_create })
        Powernode.logger.info "Queued #{command} for node instance #{node_instance.id}."
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
