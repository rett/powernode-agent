Gem::Specification.new do |s|
  s.name        = 'powernode'
  s.version     = '0.0.1'
  s.date        = '2014-05-20'
  s.summary     = 'PowerNode Management Suite Models'
  s.description = 'Models for use in PowerNode Poller, Manager, Proxy and Store'
  s.authors     = ['Everett C. Haimes III']
  s.email       = 'everett@nodealchemy.com'
  s.homepage    = 'http://www.nodealchemy.com'
  s.files       = %w[
    lib/powernode.rb
    lib/powernode/errors.rb
    lib/powernode/models.rb
    lib/powernode/net-ssh.rb
    lib/powernode/errors/execution_errors.rb
    lib/powernode/errors/initialization_errors.rb
    lib/powernode/models/extensions.rb
    lib/powernode/models/node.rb
    lib/powernode/models/node_architecture.rb
    lib/powernode/models/node_instance.rb
    lib/powernode/models/provider_instance_type.rb
    lib/powernode/models/node_module.rb
    lib/powernode/models/node_platform.rb
    lib/powernode/models/node_template.rb
    lib/powernode/models/notification.rb
    lib/powernode/models/operation.rb
    lib/powernode/models/provider.rb
    lib/powernode/models/provider_endpoint.rb
    lib/powernode/net-ssh/verbose_exec.rb
  ]
end
