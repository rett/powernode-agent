class NodeModule
  include Her::Model

  belongs_to :account

  parse_root_in_json true

  def build!(node_instance)
    if package_spec.empty?
      Powernode.logger.info "Commit aborted: No package specification."
      account.notifications.create(category: :error, summary: "Build aborted for module #{name}: No package specification")
    else
      Powernode.logger.info "Building module #{id} on instance #{node_instance.id}."
      begin
        session = Net::SSH.start(node_instance.ssh_ip_address,
                                 node_instance.admin_user,
                                 key_data: node_instance.ssh_key)
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
        account.notifications.create(category: :error, summary: "Error connecting to instance #{node_instance}\n#{e.message}")
      end
      if session
        begin
          response = session.verbose_exec!("sudo ipn -e #{build_script_id} #{id} /tmp/#{id}.spec")
          output = response[:stdout]
          error = response[:stderr]
          exit_code = response[:exit_code]
          if exit_code != 0
            account.notifications.create(category: :error, summary: "Error installing packages for module #{name}\n\n#{output}\n\n#{error}")
          end
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
          account.notifications.create(category: :error, summary: "Error installing packages for module #{name}\n\n#{e.message}")
        end
        if exit_code == 0
          Powernode.logger.info "Uploading spec for module #{id}."
          begin
            spec = session.exec!("cat /tmp/#{id}.spec")
            response = Powernode.server.post("node_modules/#{id}/upload/spec", { spec: spec })
            if response.status == 200
              account.notifications.create(category: :notice, summary: "Module spec created for module #{name}.")
            else
              account.notifications.create(category: :error, summary: "Failed to create spec for module #{name}.")
            end
          rescue => e
            Powernode.logger.error "Exception: #{e.message}."
          end
        end
      end
    end
  end

  def commit!(node_instance)
    if rsync_spec.empty?
      Powernode.logger.info "Commit aborted: No module specification."
      account.notifications.create(category: :error, summary: "Commit aborted for module #{name}: No module specification")
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
      if File.directory?(tmp_dir)
        begin
          system *%W[sudo chown root:root #{tmp_dir}]
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        begin
          system %Q[sudo rsync -arqH --numeric-ids -e "ssh -t -q -p #{Powernode.config(:ssh_port)} -o StrictHostKeyChecking=no -i #{node_instance.ssh_key_file}" --include-from=#{tmp_spec.path} #{node_instance.admin_user}@#{node_instance.ssh_ip_address}:/ #{tmp_dir}/]
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        case $?.exitstatus
        when 23
          Powernode.logger.warn "Not all files transferred for module #{id}."
          account.notifications.create(category: :warning, summary: "Not all files transferred for module #{name}")
        when 255
          Powernode.logger.error "Unable to connect."
          account.notifications.create(category: :alert, summary: "Unable to connect to instance #{node_instance.name}")
          system *%W[sudo rm -rf #{tmp_dir}]
        end
      end
      if File.directory?(tmp_dir)
        tmp_module = Tempfile.new([id, '.mo'])
        tmp_module.close
        begin
          system *%W[sudo mksquashfs #{tmp_dir} #{tmp_module.path} -comp #{Powernode.config(:module_compression)} -noappend -no-progress]
        rescue => e
          Powernode.logger.error "Exception: #{e.message}."
        end
        if tmp_module.size > 0
          payload = { data: Faraday::UploadIO.new(tmp_module.path, 'application/octet-stream') }
          response = Powernode.server.post("node_modules/#{id}/upload/data", payload)
          if response.status == 200
            account.notifications.create(category: :notice, summary: "Committed #{name} from instance #{node_instance.name}")
          else
            account.notifications.create(category: :error, summary: "Failed to commit #{name} from instance #{node_instance.name}")
          end
          FileUtils.remove_entry_secure(tmp_module, force: true)
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
      else
        Powernode.logger.error "Commit aborted for module #{id}."
      end
    end
  end
end
