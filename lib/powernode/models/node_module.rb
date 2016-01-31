class NodeModule
  include Her::Model
  parse_root_in_json true

  belongs_to :account

  def do_build(job = {})
    if (operation = Operation.find(job['id'])) && (node_instance = NodeInstance.find(operation.options['node_instance_id']))
      Powernode.logger.info "Building module #{id}."
      operation.running!
      if package_spec.empty?
        operation.failed!('Build aborted: No package specification')
      elsif lock_spec?
        operation.failed!('Build aborted: Specs locked.')
      elsif !node_instance
        operation.failed!("Build aborted: Node instance #{node_instance.name} not available.")
      elsif node_instance.status != 'active'
        operation.failed!("Build aborted: Node instance #{node_instance.name} not active.")
      else
        Powernode.logger.info "Building module #{id} on instance #{node_instance.id}."
        begin
          session = Net::SSH.start(node_instance.ssh_ip_address,
                                   node_instance.admin_user,
                                   key_data: node_instance.ssh_key)
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
          operation.failed!("Error connecting to instance #{node_instance}\n#{e.message}")
        end
        if session && operation.running?
          begin
            response = session.verbose_exec!("sudo ipn -e #{build_script_id} #{id} /tmp/#{id}.file_spec")
            output = response[:stdout]
            error = response[:stderr]
            exit_code = response[:exit_code]
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
            operation.failed!("Error installing packages for module #{name}\n\n#{e.message}")
          end
          if exit_code == 0
            Powernode.logger.info "Uploading file spec for module #{id}."
            begin
              file_spec = session.exec!("cat /tmp/#{id}.file_spec")
              response = Powernode.server.post("node_modules/#{id}/upload/file_spec", { file_spec: file_spec })
              unless response.status == 200
                operation.failed!("Failed to create file spec for module #{name}.")
              end
            rescue => e
              Powernode.logger.error "Exception: #{e.message}."
              operation.failed!("Failed to create file spec for module #{name}\n\n#{e.message}")
            end
          else
            operation.failed!("Error installing packages for module #{name}\n\n#{output}\n\n#{error}")
          end
        end
      end
      operation.complete! unless operation.failed?
    end
  end

  def do_commit(job = {})
    if (operation = Operation.find(job['id'])) && (node_instance = NodeInstance.find(operation.options['node_instance_id']))
      Powernode.logger.info "Committing module #{id}."
      operation.running!
      if rsync_spec.empty?
        operation.failed!('Commit aborted: No file specification.')
      elsif !node_instance
        operation.failed!('Commit aborted: Node instance not available.')
      elsif node_instance.status != 'active'
        operation.failed!('Commit aborted: Node instance not active.')
      else
        begin
          tmp_dir = Dir.mktmpdir("#{id}")
          FileUtils.chmod(0755, tmp_dir)
          tmp_spec = Tempfile.new([id, '.spec'])
          File.open(tmp_spec, File::RDWR|File::CREAT, 0644) do |f|
            f.flock(File::LOCK_EX)
            f.write(rsync_spec)
          end
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
          operation.failed!
        end
        if operation.running? && File.directory?(tmp_dir)
          operation.progress!(20)
          begin
            system *%W[sudo chown root:root #{tmp_dir}]
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
          begin
            system %Q[sudo rsync -arqH --numeric-ids -e "ssh -t -q -p #{Powernode.config(:ssh_port)} -o StrictHostKeyChecking=no -o PasswordAuthentication=no -i #{node_instance.ssh_key_file}" --rsync-path="sudo rsync" --include-from=#{tmp_spec.path} #{node_instance.admin_user}@#{node_instance.ssh_ip_address}:/ #{tmp_dir}/]
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
          case $?.exitstatus
          when 23
            Powernode.logger.warn "Not all files transferred for module #{id}."
            operation.add_event!(:danger, "Not all files transferred for module #{name}")
          when 255
            Powernode.logger.error "Unable to connect to instance #{node_instance.id}"
            system *%W[sudo rm -rf #{tmp_dir}]
            operation.failed!("Unable to connect to instance #{node_instance.name}")
          end
        end
        tmp_spec.unlink
        if operation.running? && File.directory?(tmp_dir)
          tmp_module = Tempfile.new([id, '.mo'])
          begin
            system *%W[sudo mksquashfs #{tmp_dir} #{tmp_module.path} -comp #{Powernode.config(:module_compression)} -noappend -no-progress]
            operation.progress!(40)
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
            operation.failed!
          end
          if tmp_module.size > 0
            payload = { data: Faraday::UploadIO.new(tmp_module.path, 'application/octet-stream') }
            response = Powernode.server.post("node_modules/#{id}/upload/data", payload)
            if response.status == 200
              operation.progress!(80)
            else
              operation.failed!("Failed to commit #{name} from instance #{node_instance.name}")
            end
            FileUtils.remove_entry_secure(tmp_module, force: true)
          end
          tmp_module.unlink
          begin
            system *%W[sudo rm -rf #{tmp_dir}]
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
            operation.failed!
          end
        end
      end
    else
      operation.failed!("Commit aborted for module #{name}: Node instance not available.")
    end
    operation.complete! unless operation.failed?
  end

  private

  def file_spec
    @file_spec ||= Powernode.server.get("node_modules/#{id}/download/file_spec").body
  end

  def package_spec
    @package_spec ||= Powernode.server.get("node_modules/#{id}/download/package_spec").body
  end

  def rsync_spec
    @rsync_spec ||= Powernode.server.get("node_modules/#{id}/download/rsync_spec").body
  end
end
