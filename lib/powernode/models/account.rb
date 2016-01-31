class Account
  include Her::Model
  parse_root_in_json true

  has_many :nodes
  has_many :operations
  has_many :provider_availability_zones
  has_many :provider_connections
  has_many :provider_instance_types
  has_many :provider_networks
  has_many :provider_network_subnets
  has_many :provider_regions

  def do_maintenance(job = {})
    operations.select { |o| !o.async? }.each do |operation|
      if operation.pending? && (!operation.scheduled_at || (Time.parse(operation.scheduled_at) < Time.now))
        operable = operation.send(operation.operable_type.underscore)
        operable.send('do_' + operation.command, operation.to_hash) if operable.respond_to?('do_' + operation.command)
      elsif operation.running? || operation.abort?
        operation.failed!
      end
    end
    running_jobs = {}
    operations.select { |o| o.async? }.each do |operation|
      if operation.pending? && (!operation.scheduled_at || Time.parse(operation.scheduled_at) < Time.now)
        running_jobs[operation.id] = Agent.perform_async(operation.to_hash.merge({ unique: UUIDTools::UUID.timestamp_create }))
      elsif operation.running? || operation.abort?
        operation.failed!
      end
    end
    while running_jobs.size > 0
      running_jobs.keys.each do |operation_id|
        status = Sidekiq::Status::status(running_jobs[operation_id])
        case status
        when :complete
          running_jobs.delete(operation_id)
        when :failed, nil
          running_jobs.delete(operation_id)
        end
        sleep Powernode.config(:job_interval)
      end
    end
    command = 'maintenance'
    nodes.each do |node|
      Agent.perform_async({ command: command, operable_type: 'node', operable_id: node.id })
    end
  end
end
