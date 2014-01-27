class Node
  include PowerNode::ModelExtensions

  def build_objects
    self.node_architecture = NodeArchitecture.new(node_architecture) if self.respond_to?(:node_architecture)
    self.node_instance_type = NodeInstanceType.new(node_instance_type) if self.respond_to?(:node_instance_type)
    self.node_instances = node_instances.map { |i| NodeInstance.new(i) } if self.respond_to?(:node_instances)
    self.node_modules = node_modules.map { |m| NodeModule.new(m) } if self.respond_to?(:node_modules)
    self.node_platform = NodePlatform.new(node_platform) if self.respond_to?(:node_platform)
    self.node_template = NodeTemplate.new(node_template) if self.respond_to?(:node_template)
    self.provider = Provider.new(provider) if self.respond_to?(:provider)
    self.provider_endpoint = ProviderEndpoint.new(provider_endpoint) if self.respond_to?(:provider_endpoint)
    self.operations = operations.map { |o| Operation.new(o) } if self.respond_to?(:operations)
    if self.respond_to?(:puppet_modules)
      self.puppet_modules = puppet_modules.map { |m| PuppetModule.new(m) }
      self.puppet_modules.map { |m| m.puppet_resources = m.puppet_resources.map { |r| PuppetResource.new(r) } }
    end
  end

  def cloud_instances
    node_instances.select { |i| i.cloud }.sort_by { |i| i.primary ? 0 : 1 } if self.respond_to?(:node_instances)
  end

  def physical_instances
    node_instances.select { |i| !i.cloud } if self.respond_to?(:node_instances)
  end

  def primary_instance
    cloud_instances.select { |i| i.primary }.first if self.respond_to?(:node_instances)
  end

  def instance_variance
    self.respond_to?(:instance_count) ? instance_count - cloud_instances.count : 0
  end

  def ssh_key_file
    File.join(PowerNode.config(:ssh_key_dir), "#{id}.pem")
  end
end
