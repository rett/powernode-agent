class Net::SSH::Connection::Session
  def verbose_exec!(command)
    stdout_data = ''
    stderr_data = ''
    exit_code = nil
    exit_signal = nil
    self.open_channel do |channel|
      channel.exec(command) do |_, success|
        raise CommandExecutionFailed, "Unable to execute command: #{command}" unless success
        channel.on_data do |_, data|
          stdout_data += data
        end
        channel.on_extended_data do |ch, type, data|
          stderr_data += data
        end
        channel.on_request('exit-status') do |ch, data|
          exit_code = data.read_long
        end
        channel.on_request('exit-signal') do |ch, data|
          exit_signal = data.read_long
        end
      end
    end
    self.loop
    { stdout: stdout_data, stderr: stderr_data, exit_code: exit_code, exit_signal: exit_signal }
  end
end
