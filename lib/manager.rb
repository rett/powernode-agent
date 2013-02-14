#!/usr/bin/env ruby
$:.unshift File.dirname(__FILE__)
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), '..', 'Gemfile')

require 'rubygems'
require 'bundler/setup'
require 'active_support/time'
require 'fog'
require 'json'
require 'net/ssh'
require 'net/sftp'
require 'openssl'
require 'pony'
require 'restclient'
require 'sidekiq'
require 'sidekiq-unique-jobs'
require 'tmpdir'
require 'powernode'
require 'powernode/models'

class Manager
  include Powernode
  include Sidekiq::Worker

  Pony.options = { from: Powernode.config(:smtp_from_email), via: :smtp,
                     via_options: { address:              Powernode.config(:smtp_server),
                                    port:                 Powernode.config(:smtp_port),
                                    domain:               Powernode.config(:smtp_domain),
                                    user_name:            Powernode.config(:smtp_user_name),
                                    password:             Powernode.config(:smtp_password),
                                    authentication:       Powernode.config(:smtp_authentication),
                                    enable_starttls_auto: Powernode.config(:smtp_enable_starttls_auto) } }

  Powernode.logger_init(Powernode.config(:manager_logfile), Powernode.config(:manager_loglevel))

  Sidekiq.configure_server do |config|
    config.logger = Powernode.logger
    config.redis = { namespace: Powernode.config(:redis_namespace), url: Powernode.config(:redis_server) }
  end

  sidekiq_options queue: Powernode.config(:manager_queue),
                  retry: Powernode.config(:job_retries),
                  unique: true,
                  unique_job_expiration: Powernode.config(:manager_job_expiration)

  def perform(message)
    operation = ActiveSupport::JSON.decode(message)
    command = operation['command']
    params = operation['params']
    node_id = params['node_id']
    @parent_resource = RestClient::Resource.new(Powernode.config(:parent_url) + '/api/v1',
                                                Powernode.config(:id),
                                                Powernode.config(:key))
    begin
      @node = Node.new(JSON.parse(@parent_resource["node/#{node_id}.json"].get))
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
    if @node
      compute = { provider: 'AWS',
                  endpoint: @node.node_provider.aws_endpoint,
                  aws_access_key_id: @node.node_provider.aws_access_key_id,
                  aws_secret_access_key: @node.node_provider.aws_secret_access_key }
      @cloud = Fog::Compute.new(compute)
      @stamp = "[#{command}:#{@node.id}]"
      if @node.dirty?
        dirty_attributes = Powernode.config(:encrypted_attributes).map { |a| @node.respond_to?("#{a}_dirty") ? { a.to_sym => @node.send('raw_' + a) } : nil }.compact
        begin
          @parent_resource["node/#{@node.id}.json"].post(node: dirty_attributes)
        rescue Exception => e
          logger.error "#{@stamp} Exception: #{e.message}"
        end
      end
      if @node.node_provider.dirty?
        dirty_attributes = Powernode.config(:encrypted_attributes).map { |a| @node.node_provider.respond_to?(a) ? { a.to_sym => @node.node_provider.send('raw_' + a) } : nil }.compact
        begin
          @parent_resource["node/#{@node.id}/provider/#{@node.node_provider.id}.json"].post(node_provider: dirty_attributes)
        rescue Exception => e
          logger.error "#{@stamp} Exception: #{e.message}"
        end
      end
      @node = Node.new(JSON.parse(@parent_resource["node/#{node_id}.json"].get)) if dirty_attributes
      send("do_#{command}", params) if respond_to?("do_#{command.to_s}")
    end
  end

  protected

  def do_poll_node(params)
    do_operations(params)
    poll_cloud_instances
    poll_physical_instances
  end

  def do_operations(params)
    if @node.operations.is_a?(Array) && @node.operations.count > 0
      @node.operations.each do |operation|
        command = operation['command']
        params = operation['params']
        if params['scheduled_at'].empty? || (params['scheduled_at'] && Time.parse(params['scheduled_at']) < Time.now)
          logger.info "#{@stamp} Performing command: #{command} on node #{@node.id}."
          send("do_#{command}", params) if respond_to?("do_#{command}")
          @parent_resource['node']["#{@node.id}.json"].post(command: command, params: params)
        end
      end
    end
  end

  def do_instance_exec(params)
    exec = params['exec']
    node_instance_id = params['node_instance_id']
    node_instance = @node.node_instances.select { |i| i.id == node_instance_id }.first
    logger.info "#{@stamp} Executing (#{exec}) on #{node_instance.name}..."
    begin
      session = Net::SSH.start(node_instance.private_ip_address,
                               @node.admin_user,
                               key_data: @node.ssh_key,
                               paranoid: false)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
    if session
      begin
        session.exec!("sudo #{exec}")
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
    end
  end

  def do_instance_terminate(params)
    node_instance_id = params['node_instance_id']
    node_instance = @node.node_instances.select { |i| i.id == node_instance_id }.first
    logger.info "#{@stamp} Terminating instance #{node_instance.name}..."
    destroy_cloud_instance(node_instance)
  end

  def do_create_iso(params)
    logger.info "#{@stamp} Creating ISO for node: #{@node.id}"
    @node_instance = @node.node_instances.select { |i| i.id == params['node_instance_id'] }.first if params['node_instance_id']
    kernel_file = File.join(Powernode.config(:kernel_path), "#{@node.id}.kernel")
    ramdisk_file = File.join(Powernode.config(:kernel_path), "#{@node.id}.ramdisk")
    unless File.exists?(kernel_file) && Digest::SHA2.new(Powernode.config(:checksum_bitlength)).hexdigest(File.binread(kernel_file)) == @node.node_platform.kernel_checksum
      logger.info "#{@stamp} Downloading kernel for platform #{@node.node_platform.id}."
      begin
        FileUtils.mkdir_p(Powernode.config(:kernel_path))
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
      begin
        File.open(kernel_file, 'w') { |f| f.write(@parent_resource["node/#{@node.id}/platform_kernel.html"].get) }
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
    end
    unless File.exists?(ramdisk_file) && Digest::SHA2.new(Powernode.config(:checksum_bitlength)).hexdigest(File.binread(ramdisk_file)) == @node.node_platform.ramdisk_checksum
      logger.info "#{@stamp} Downloading ramdisk for platform #{@node.node_platform.id}."
      begin
        FileUtils.mkdir_p(Powernode.config(:kernel_path))
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
      begin
        File.open(ramdisk_file, 'w') { |f| f.write(@parent_resource["node/#{@node.id}/platform_ramdisk.html"].get) }
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
    end

    tmp_dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(tmp_dir, 'modules'))

    begin
      node_modules = JSON.parse(@parent_resource["node/#{@node.id}/modules.json"].get).map { |m| NodeModule.new(m) }
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end

    if node_modules
      node_modules.each do |node_module|
        module_file_name = "#{node_module.id}-#{node_module.data_file_version}#{Powernode.config(:module_extension)}"
        module_file = File.join(tmp_dir, 'modules', module_file_name)
        File.open(module_file, 'w') { |f| f << @parent_resource["node/#{@node.id}/module/#{node_module.id}.html"].get }
        module_info_file_name = "#{node_module.id}-#{node_module.data_file_version}#{Powernode.config(:module_info_extension)}"
        module_info = File.join(tmp_dir, 'modules', module_info_file_name)
        File.open(module_info, 'w') { |f| f << @parent_resource["node/#{@node.id}/module/#{node_module.id}.text"].get }
      end
    end

    node_cfg_file = File.join(tmp_dir, 'node.cfg')
    begin
      File.open(node_cfg_file, 'w') do |f|
        f.puts(node_config)
      end
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end

    volume_cfg_file = File.join(tmp_dir, 'volume.cfg')
    begin
      File.open(volume_cfg_file, 'w') do |f|
        f.puts("modules=modules")
      end
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end

    FileUtils.mkdir_p(File.join(tmp_dir, 'syslinux'))
    FileUtils.cp(File.join(Powernode.config(:syslinux_path), 'isolinux.bin'), File.join(tmp_dir, 'syslinux'))
    FileUtils.cp(File.join(Powernode.config(:syslinux_path), 'isolinux.cfg'), File.join(tmp_dir, 'syslinux'))
    FileUtils.cp(kernel_file, File.join(tmp_dir, 'syslinux', 'kernel'))
    FileUtils.cp(ramdisk_file, File.join(tmp_dir, 'syslinux', 'ramdisk'))

    node_iso_file = Tempfile.new("#{@node.id}.iso-")
    FileUtils.chmod(0644, node_iso_file)
    system("mkisofs -o #{node_iso_file.path} -b syslinux/isolinux.bin -c boot.cat -R -J -no-emul-boot -boot-load-size 4 -boot-info-table #{tmp_dir}")

    if node_iso_file.size > 0
      begin
        @node = Node.new(JSON.parse(@parent_resource["node/#{@node.id}/iso.json"].post(
          node_instance_id: @node_instance.id,
          iso: File.open(node_iso_file),
          multipart: true,
          content_type: 'application/octet-stream',
          accept: :json)))
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
    end
    FileUtils.remove_entry_secure(tmp_dir)
  end

  def do_node_module_commit(params)
    node_module_id = params['node_module_id']
    node_module = NodeModule.new(JSON.parse(@parent_resource["node/#{@node.id}/module/#{node_module_id}.json"].get))
    logger.info "#{@stamp} Committing module #{node_module.id}."
    if @node.primary_instance && !node_module.effective_spec.empty?
      tmp_dir = Dir.mktmpdir
      FileUtils.chmod(0755, tmp_dir)
      begin
        tmp_spec = Tempfile.new("spec-#{@node.id}-#{node_module.id}")
        File.open(tmp_spec, 'w') do |f|
          node_module.effective_spec.each do |l|
            f.write(Base64.decode64(l) + "\n")
          end
        end
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
        FileUtils.remove_entry_secure(tmp_dir)
      end
      begin
        system("sudo rsync -lptgoDH -e \"ssh -q -p #{Powernode.config(:ssh_port)} -o StrictHostKeyChecking=no -i #{@node.ssh_key_file}\" --files-from=#{tmp_spec.path} #{@node.admin_user}@#{@node.primary_instance.private_ip_address}:/ #{tmp_dir}/")
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
      if File.directory?(tmp_dir)
        tmp_module = Tempfile.new("module-#{@node.id}-#{node_module.id}")
        tmp_module.close
        begin
          system("sudo mksquashfs #{tmp_dir} #{tmp_module.path} -comp #{Powernode.config(:module_compression)} -noappend -no-progress > /dev/null")
        rescue Exception => e
          logger.error "#{@stamp} Exception: #{e.message}"
        end
        if tmp_module.size > 0
          begin
            new_node_module = NodeModule.new(JSON.parse(@parent_resource["node/#{@node.id}/module/#{node_module.id}.json"].post(
              data: File.open(tmp_module),
              multipart: true,
              content_type: 'application/octet-stream',
              accept: :json)))
          rescue Exception => e
            logger.error "#{@stamp} Exception: #{e.message}"
          end
          FileUtils.remove_entry_secure(tmp_dir, force: true)
          FileUtils.remove_entry_secure(tmp_module, force: true)
          logger.info "#{@stamp} Commit complete for node module #{node_module.id}."
        else
          logger.info "#{@stamp} Commit aborted."
        end
      end
    elsif @node.primary_instance.nil?
      logger.info "#{@stamp} Commit aborted: No primary instance found!"
    else
      logger.info "#{@stamp} Commit aborted: No module specification!"
    end
  end

  def do_send_ssh_key(params)
    recipient = params['recipient']
    encryption_key = params['encryption_key']
    logger.info "#{@stamp} Delivering SSH key to #{recipient}."
    if encryption_key && encryption_key.is_a?(String) && encryption_key.length == Powernode.config(:encryption_key_length)
      encryption_key = [encryption_key].pack('H*')
      cipher = OpenSSL::Cipher.new(Powernode.config(:encryption_cipher))
      cipher.encrypt
      cipher.key = encryption_key
      iv = cipher.random_iv
      encrypted_ssh_key = Base64.encode64(cipher.update(@node.ssh_key) + cipher.final)
    else
      encrypted_ssh_key = @node.ssh_key
    end
    body =<<END
Attached is the encrypted SSH key for node #{@node.name}.

You must decrypt the ssh key with the following command:
$ openssl #{Powernode.config(:encryption_cipher)} -base64 -d -in #{@node.name + '.pem.sha'} -out #{@node.name + '.pem'} -iv #{iv.unpack('H*')[0]} -K [insert your key here]

And change the file permissions:
$ chmod 600 #{@node.name + '.pem'}

In order to SSH in to an instance, do so by specifying the private key, for example:
$ ssh -i #{@node.name + '.pem'} #{@node.admin_user}@#{@node.primary_instance.public_ip_address}

Thanks,
Node Alchemy
END
    begin
      Pony.mail(
        to: recipient,
        subject: "SSH key for #{@node.name}",
        body: body,
        attachments: { "#{@node.name}.pem.sha" => encrypted_ssh_key },
        headers: { "Content-Type" => "multipart/mixed", "Content-Transfer-Encoding" => "base64", "Content-Disposition" => "attachment" },
      )
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
  end

  def do_update_cloud_instances(params)
    if @node.enabled
      @node.cloud_instances.each do |node_instance|
        logger.info "#{@stamp} Triggering update on instance: #{node_instance.name}."
        if node_instance.private_ip_address && @node.ssh_key
          begin
            session.exec!("sudo /usr/sbin/ipn -u")
          rescue Exception => e
            logger.error "#{@stamp} Exception: #{e.message}"
          end
        end
        @parent_resource["node/#{@node.id}/instance.json"].post(node_instance: node_instance.to_json)
      end
    end
  end

  private

  def destroy_cloud_instances(cloud_instances, count)
    count.times do |n|
      node_instance = cloud_instances.reverse[n]
      destroy_cloud_instance(node_instance)
    end
  end

  def destroy_cloud_instance(node_instance)
    logger.info "#{@stamp} Destroying instance: #{node_instance.name}"
    begin
      if @cloud.servers.destroy(node_instance.name)
        @parent_resource["node/#{@node.id}/instance/#{node_instance.id}.json"].delete
        @node.node_instances.delete_if { |i| i.id == node_instance.id }
      end
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
  end

  def launch_instances(count = 1)
    logger.info "#{@stamp} Loading key."
    keypair_name = @node.id
    keys = []
    begin
      logger.info "#{@stamp} Attempting to retrieve keypairs..."
      keys = @cloud.key_pairs.all
      key = keys.select { |k| k.name == keypair_name }.first
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
    if key && key.fingerprint == @node.ssh_key_fingerprint
      logger.info "#{@stamp} Found valid key: #{keypair_name}"
    else
      begin
        logger.info "#{@stamp} Deleting key: #{keypair_name}"
        @cloud.delete_key_pair(keypair_name)
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
      begin
        logger.info "#{@stamp} Creating key: #{keypair_name}"
        key = @cloud.key_pairs.create(name: keypair_name)
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
      logger.info "#{@stamp} Using key: #{keypair_name}"
      if key && key.private_key
        node_attributes = { ssh_key: Powernode.encrypt(key.private_key), ssh_key_fingerprint: key.fingerprint }
        if @parent_resource["node/#{@node.id}"].post(node: node_attributes)
          if (ssh_key_path = Powernode.config(:ssh_key_path))
            FileUtils.mkdir_p(ssh_key_path)
            FileUtils.touch(@node.ssh_key_file)
            FileUtils.chmod(0600, @node.ssh_key_file)
            File.open(@node.ssh_key_file, 'w') { |f| f.write(key.private_key) }
          end
        end
      end
    end
    count.times do
      instance_options = {}
      instance_options[:availability_zone] = @node.node_provider.aws_availability_zone if @node.node_provider.aws_availability_zone
      instance_options[:image_id] = @node.node_provider.image_id if !@node.node_provider.image_id.empty?
      instance_options[:ramdisk_id] = @node.node_provider.ramdisk_id if !@node.node_provider.ramdisk_id.empty?
      instance_options[:flavor_id] = @node.node_instance_type.name
      instance_options[:region] = @node.node_provider.region
      instance_options[:key_name] = key.name
      instance_options[:user_data] = node_config
      begin
        if (cloud_instance = @cloud.servers.create(instance_options))
          logger.info "#{@stamp} Created new instance: #{cloud_instance.id}"
          node_instance = NodeInstance.new({ name: cloud_instance.id,
                                             cloud: true,
                                             private_ip_address: cloud_instance.private_ip_address,
                                             public_ip_address: cloud_instance.public_ip_address,
                                             state: cloud_instance.state,
                                             started_at: cloud_instance.created_at })
          unless @parent_resource["node/#{@node.id}/instance.json"].post(node_instance: node_instance.to_json)
            @cloud.servers.destroy(cloud_instance.id)
          end
        end
      rescue Exception => e
        logger.error "#{@stamp} Exception: #{e.message}"
      end
    end
  end

  def poll_cloud_instances
    logger.info "#{@stamp} Performing cloud instance check."
    logger.info "#{@stamp} Instance variance: #{@node.instance_variance}"
    begin
      @parent_resource['node']["#{@node.id}.json"].post(poll: true)
    rescue Exception => e
      logger.error "#{@stamp} Exception: #{e.message}"
    end
    if @cloud
      if @node.enabled
        if @node.cloud_instances.count > 0
          @node.cloud_instances.each do |node_instance|
            begin
              cloud_instance = @cloud.servers.get(node_instance.name)
              aws_available = true
            rescue Exception => e
              logger.error "#{@stamp} Exception: #{e.message}"
            end
            if aws_available
              if cloud_instance && cloud_instance.flavor_id == @node.node_instance_type.name
                logger.info "#{@stamp} Updating instance: #{cloud_instance.id}"
                node_instance.private_ip_address = cloud_instance.private_ip_address
                node_instance.public_ip_address = cloud_instance.public_ip_address
                node_instance.state = cloud_instance.state
                @parent_resource["node/#{@node.id}/instance/#{node_instance.id}.json"].post(node_instance: node_instance.to_json)
              elsif cloud_instance && cloud_instance.flavor_id != @node.node_instance_type.name
                logger.info "#{@stamp} Node instance type incorrect for instance: #{cloud_instance.id}"
                destroy_cloud_instance(node_instance)
              else
                logger.info "#{@stamp} Deregistering invalid instance: #{node_instance.name}"
                @parent_resource["node/#{@node.id}/instance/#{node_instance.id}.json"].delete
                @node.node_instances.delete(node_instance)
              end
            end
          end
        end
        if @node.instance_variance > 0
          logger.info "#{@stamp} Launching #{@node.instance_variance} instances."
          launch_instances(@node.instance_variance)
        elsif @node.instance_variance < 0
          logger.info "#{@stamp} Destroying #{@node.instance_variance} instances."
          destroy_cloud_instances(@node.cloud_instances, @node.instance_variance.abs)
        end
      elsif @node.cloud_instances.count > 0
        destroy_cloud_instances(@node.cloud_instances, @node.cloud_instances.count)
      end
    end
    logger.info "#{@stamp} Cloud instance check complete."
  end

  def poll_physical_instances
    logger.info "#{@stamp} Performing physical instance check."
    @node.physical_instances.each do |node_instance|
      logger.info "#{@stamp} Checking physical instance #{node_instance.id}"
    end
    logger.info "#{@stamp} Physical instance check complete."
  end

  private

  def node_config
    <<END
export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ID=#{@node_instance ? @node_instance.id : @node.id}
KEY=#{@node.manager_key}
PARENT=#{Powernode.config(:proxy_url).nil? ? Powernode.config(:parent_url) : Powernode.config(:proxy_url)}
API_URL="#{Powernode.config(:api_url)}"
ADMIN_USER=#{@node.admin_user}
EPHEMERAL=#{@node.ephemeral}
PROVISIONAL=#{@node_instance && !@node_instance.cloud ? 'true' : 'false'}
CHKSUM=#{Powernode.config(:checksum_util)}
MAXLOOP=#{Powernode.config(:loop_devices)}
MEMORY=#{Powernode.config(:memory_dir)}
BRANCHES=#{Powernode.config(:branches_dir)}
CHANGES=#{Powernode.config(:changes_dir)}
RAM=#{Powernode.config(:ram_dir)}
VOLUMES=#{Powernode.config(:volumes_dir)}
MODULES=#{Powernode.config(:modules_dir)}
MODULE_EXT=#{Powernode.config(:module_extension)}
MODULE_INFO_EXT=#{Powernode.config(:module_info_extension)}
MODULE_UPDATE_EXT=#{Powernode.config(:module_update_extension)}
TMPFS_STORE=#{@node.tmpfs_store}
END
  end
end
