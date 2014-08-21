class Node
  include Her::Model
  include Powernode::Encryption

  belongs_to :account
  belongs_to :node_instance_type
  belongs_to :node_platform
  belongs_to :node_template
  belongs_to :provider
  has_many :node_instances
  has_many :node_modules
  has_many :operations
  has_many :volumes

  delegate :node_architecture, to: :node_template
  delegate :provider_endpoint, to: :provider

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

  def dynamic_instance_variance
    self.respond_to?(:dynamic_instance_count) ? dynamic_instance_count - dynamic_instances.count : 0
  end

  def key
    unless @key
      keypair_name = id
      keys = []
      begin
        Powernode.logger.info "Retrieving keypairs for node #{id}."
        keys = provider.compute.key_pairs.all
        @key = keys.select { |k| k.name == keypair_name }.first
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      if @key && @key.fingerprint == ssh_key_fingerprint && File.exist?(ssh_key_file)
        Powernode.logger.info "Found valid key for node #{id}."
      else
        begin
          Powernode.logger.info "Creating new key for node #{id}."
          @key = provider.compute.key_pairs.create(name: keypair_name)
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
    key_dir = Powernode.config(:ssh_key_dir)
    key_file = File.join(key_dir, "#{id}.pem")
    unless File.exist?(key_file)
      FileUtils.mkdir_p(key_dir)
      File.open(key_file, File::RDWR|File::CREAT, 0600) do |f|
        f.flock(File::LOCK_EX)
        f.write(ssh_key)
        f.flush
        f.truncate(f.pos)
      end
    end
    key_file
  end

  def init_sync!
    init_dir = Powernode.config(:init_dir)
    FileUtils.mkdir_p(init_dir)
    %w[kernel ramdisk].each do |resource|
      init_resource = File.join(init_dir, "#{node_architecture.id}.#{resource}")
      resource_checksum = node_architecture.send("#{resource}_checksum")
      if resource_checksum.present? && (!File.exists?(init_resource) || resource_checksum != Digest::SHA2.new(Powernode.config(:checksum_bitlength)).hexdigest(File.binread(init_resource)))
        Powernode.logger.info "Downloading #{resource} for architecture #{node_architecture.id}."
        response = Powernode.server.get("architectures/#{node_architecture.id}/download/#{resource}")
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

  def launch_instance!(variety = 'cloud')
    if node_instances.count + 1 <= instance_limit
      Powernode.logger.info "Creating new instance for node #{id}."
      node_instance = NodeInstance.new(id: UUIDTools::UUID.timestamp_create, node_id: id)
      node_instance.agent_key = SecureRandom.urlsafe_base64(Powernode.config(:instance_key_length))
      node_instance.key = node_instance.agent_key
      node_instance.node_instance_type_id = node_instance_type.id
      node_instance.variety = variety
      case provider.endpoint_type
      when 'openstack'
        flavor = provider.compute.flavors.find { |f| f.name == node_instance_type.name }.id
      else
        flavor = node_instance_type.name
      end
      instance_options = {}
      instance_options[:name]               = node_instance.id
      instance_options[:user_data]          = node_instance.identity
      instance_options[:availability_zone]  = provider.availability_zone  if provider.availability_zone.present?
      instance_options[:image_id]           = provider.machine_image      if provider.machine_image.present?
      instance_options[:image_ref]          = provider.machine_image      if provider.machine_image.present?
      instance_options[:kernel_id]          = provider.kernel_image       if provider.kernel_image.present?
      instance_options[:ramdisk_id]         = provider.ramdisk_image      if provider.ramdisk_image.present?
      instance_options[:region]             = provider.region             if provider.region.present?
      instance_options[:flavor_id]          = flavor
      instance_options[:flavor_ref]         = flavor
      instance_options[:key_name]           = key.name
      begin
        cloud_instance = provider.compute.servers.create(instance_options)
        cloud_instance.wait_for { ready? }
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
      if cloud_instance
        node_instance.entity = cloud_instance.id
        node_instance.name = cloud_instance.id
        node_instance.private_ip_address = cloud_instance.private_ip_address
        node_instance.provider_id = provider.id
        node_instance.public_ip_address = cloud_instance.public_ip_address
        node_instance.status = cloud_instance.state
        node_instance.started_at = cloud_instance.respond_to?(:created_at) ? cloud_instance.created_at : cloud_instance.created
        if node_instance.save
          Powernode.logger.info "Created instance #{cloud_instance.id}."
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
      account.notifications.create(category: :notice, summary: "Created cloud instance #{node_instance.name}.")
    elsif node_instance.nil?
      account.notifications.create(category: :error, summary: 'Failed to create new instance!')
    end
    node_instance
  end

  def send_ssh_key!(options)
    recipient = options['recipient']
    encryption_key = options['encryption_key']
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

  def terminate_dynamic_instances!(count)
    count.times do
      node_instance = dynamic_instances.last
      node_instance.terminate!
    end
  end
end
