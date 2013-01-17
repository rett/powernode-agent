class Node
  include Powernode::ModelExtensions
  def build_objects
    self.node_instance_type  = NodeInstanceType.new(node_instance_type) if self.respond_to?(:node_instance_type)
    self.node_instances = node_instances.collect { |i| NodeInstance.new(i) } if self.respond_to?(:node_instances)
    self.node_modules   = node_modules.collect { |m| NodeModule.new(m) } if self.respond_to?(:node_modules)
    self.node_platform  = NodePlatform.new(node_platform) if self.respond_to?(:node_platform)
    self.node_provider  = NodeProvider.new(node_provider) if self.respond_to?(:node_provider)
    self.node_template  = NodeTemplate.new(node_template) if self.respond_to?(:node_template)
  end

  def cloud_instances
    node_instances.select { |i| i.cloud == true } if self.respond_to?(:node_instances)
  end

  def physical_instances
    node_instances.select { |i| i.cloud == false } if self.respond_to?(:node_instances)
  end

  def primary_instance
    cloud_instances.select { |i| i.primary == true }.first if self.respond_to?(:node_instances)
  end

  def instance_variance
    self.respond_to?(:instance_count) ? instance_count - cloud_instances.count : 0
  end

  def ssh_key_file
    File.join(Powernode.config(:ssh_key_path), "#{id}.pem")
  end
end
