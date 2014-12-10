# coding: utf-8
# lib = File.expand_path('../lib', __FILE__)
# $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = 'powernode'
  spec.version       = Powernode::VERSION
  spec.authors       = ['Everett C. Haimes III']
  spec.email         = ['everett@nodealchemy.com']
  spec.summary       = %q{Powernode Modular System Management}
  spec.description   = %q{Powernode core functionality}
  spec.homepage      = 'http://www.nodealchemy.com'
  spec.license       = ''
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 2.0'
  spec.add_development_dependency 'bundler', '~> 1.7'
  spec.add_development_dependency 'rake', '~> 10.0'

  spec.files = %w[
    lib/powernode/errors/execution_errors.rb
    lib/powernode/errors.rb
    lib/powernode/models/account.rb
    lib/powernode/models/node.rb
    lib/powernode/models/node_architecture.rb
    lib/powernode/models/node_instance.rb
    lib/powernode/models/node_module.rb
    lib/powernode/models/node_platform.rb
    lib/powernode/models/node_template.rb
    lib/powernode/models/notification.rb
    lib/powernode/models/operation.rb
    lib/powernode/models/provider.rb
    lib/powernode/models/provider_connection.rb
    lib/powernode/models/provider_instance_type.rb
    lib/powernode/models/provider_network.rb
    lib/powernode/models/provider_network_subnet.rb
    lib/powernode/models/provider_region.rb
    lib/powernode/models/provider_volume.rb
    lib/powernode/models/provider_volume_member.rb
    lib/powernode/models/provider_volume_snapshot.rb
    lib/powernode/models/provider_volume_type.rb
    lib/powernode/models.rb
    lib/powernode/net-ssh/verbose_exec.rb
    lib/powernode/net-ssh.rb
    lib/powernode.rb
  ]
end
