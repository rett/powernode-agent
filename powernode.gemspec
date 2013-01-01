Gem::Specification.new do |s|
  s.name        = 'powernode'
  s.version     = '0.0.1'
  s.date        = '2012-12-12'
  s.summary     = 'Powernode Management Suite Models'
  s.description = 'Models for use in Powernode Poller, Manager, Proxy and Store'
  s.authors     = ['Everett C. Haimes III']
  s.email       = 'everett@nodealchemy.com'
  s.homepage    = 'http://www.nodealchemy.com'
  s.files       = [
      'lib/powernode.rb',
      'lib/powernode/model_extensions.rb',
      'lib/powernode/node.rb',
      'lib/powernode/node_instance.rb',
      'lib/powernode/node_instance_type.rb',
      'lib/powernode/node_module.rb',
      'lib/powernode/node_platform.rb',
      'lib/powernode/node_provider.rb',
      'lib/powernode/node_template.rb'
  ]
end
