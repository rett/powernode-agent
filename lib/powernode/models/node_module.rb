class NodeModule
  include Her::Model
  parse_root_in_json true

  belongs_to :account

  def do_build(job = {})
    if (operation = Operation.find(job['id'])) && (node_instance = NodeInstance.find(operation.options['node_instance_id']))
      if package_spec.empty?
        Powernode.logger.info 'Commit aborted: No package specification.'
        operation.add_event!(:danger, 'Build aborted: No package specification')
      elsif lock_spec?
        Powernode.logger.info 'Commit aborted: Spec locked.'
        operation.add_event!(:danger, 'Commit aborted: Spec locked.')
      elsif !node_instance
        Powernode.logger.info "Commit aborted: Node instance not available."
        operation.add_event!(:danger, 'Commit aborted: Node instance not available.')
      else
        Powernode.logger.info "Building module #{id} on instance #{node_instance.id}."
        begin
          session = Net::SSH.start(node_instance.ssh_ip_address,
                                   node_instance.admin_user,
                                   key_data: node_instance.ssh_key)
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
          operation.add_event!(:danger, "Error connecting to instance #{node_instance}\n#{e.message}")
          operation.failed!
        end
        if session && operation.running?
          begin
            response = session.verbose_exec!("sudo ipn -e #{build_script_id} #{id} /tmp/#{id}.spec")
            output = response[:stdout]
            error = response[:stderr]
            exit_code = response[:exit_code]
            if exit_code != 0
              operation.add_event!(:danger, "Error installing packages for module #{name}\n\n#{output}\n\n#{error}")
            end
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
            operation.add_event!(:danger, "Error installing packages for module #{name}\n\n#{e.message}")
          end
          if exit_code == 0
            Powernode.logger.info "Uploading spec for module #{id}."
            begin
              spec = session.exec!("cat /tmp/#{id}.spec")
              response = Powernode.server.post("node_modules/#{id}/upload/spec", { spec: spec })
              if response.status == 200
                operation.add_event!(:info, "Module spec created for module #{name}.")
              else
                operation.add_event!(:danger, "Failed to create spec for module #{name}.")
              end
            rescue => e
              Powernode.logger.error "Exception: #{e.message}."

            end
          end
        end
      end
      operation.running?
    else
      false
    end
  end

  def do_commit(job = {})
    if (operation = Operation.find(job['id'])) && (node_instance = NodeInstance.find(operation.options['node_instance_id']))
      if rsync_spec.empty?
        operation.add_event!(:danger, "Commit aborted for module #{name}: No module specification")
      else
        Powernode.logger.info "Committing module #{id}."
        tmp_dir = Dir.mktmpdir("#{id}")
        FileUtils.chmod(0755, tmp_dir)
        begin
          tmp_spec = Tempfile.new([id, '.spec'])
          File.open(tmp_spec, File::RDWR|File::CREAT, 0644) do |f|
            f.flock(File::LOCK_EX)
            f.write(rsync_spec)
          end
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        operation.progress!(20)
        if File.directory?(tmp_dir)
          begin
            system *%W[sudo chown root:root #{tmp_dir}]
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
          begin
            system %Q[sudo rsync -arqH --numeric-ids -e "ssh -t -q -p #{Powernode.config(:ssh_port)} -o StrictHostKeyChecking=no -i #{node_instance.ssh_key_file}" --rsync-path="sudo rsync" --include-from=#{tmp_spec.path} #{node_instance.admin_user}@#{node_instance.ssh_ip_address}:/ #{tmp_dir}/]
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
          case $?.exitstatus
          when 23
            Powernode.logger.warn "Not all files transferred for module #{id}."
            operation.add_event!(:danger, "Not all files transferred for module #{name}")
          when 255
            Powernode.logger.error "Unable to connect to instance #{node_instance.id}"
            operation.add_event!(:danger, "Unable to connect to instance #{node_instance.name}")
            system *%W[sudo rm -rf #{tmp_dir}]
          end
        end
        tmp_spec.unlink
        operation.progress!(30)
        if File.directory?(tmp_dir)
          tmp_module = Tempfile.new([id, '.mo'])
          begin
            system *%W[sudo mksquashfs #{tmp_dir} #{tmp_module.path} -comp #{Powernode.config(:module_compression)} -noappend -no-progress]
            operation.progress!(40)
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
          if tmp_module.size > 0
            payload = { data: Faraday::UploadIO.new(tmp_module.path, 'application/octet-stream') }
            response = Powernode.server.post("node_modules/#{id}/upload/data", payload)
            if response.status == 200
              operation.add_event!(:info, "Committed #{name} from instance #{node_instance.name}")
            else
              operation.add_event!(:danger, "Failed to commit #{name} from instance #{node_instance.name}")
            end
            FileUtils.remove_entry_secure(tmp_module, force: true)
            operation.progress!(60)
            begin
              system *%W[sudo rm -rf #{tmp_dir}]
            rescue => e
              Powernode.logger.error "Exception: #{e.message}."
            end
            Powernode.logger.info "Commit complete for module #{id}."
          else
            system *%W[sudo rm -rf #{tmp_dir}]
            Powernode.logger.error "Commit aborted for module #{id}."
          end
          tmp_module.unlink
        else
          Powernode.logger.error "Commit aborted for module #{id}."
        end
      end
      true
    else
      Powernode.logger.info "Commit aborted for module #{id}: Node instance not available"
      operation.add_event!(:danger, "Commit aborted for module #{name}: Node instance not available")
      false
    end
  end

  private

  def package_spec
    @package_spec ||= Powernode.server.get("node_modules/#{id}/download/package_spec").body
  end

  def rsync_spec
    @rsync_spec ||= Powernode.server.get("node_modules/#{id}/download/rsync_spec").body
  end

  def spec
    @spec ||= Powernode.server.get("node_modules/#{id}/download/spec").body
  end
end
