require 'daemons'

daemon_options = {
  :dir        => 'monitor',
  :log_output => true,
  :monitor    => true
}

Daemons.run('powernode_manager.rb', daemon_options)
