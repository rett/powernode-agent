class Account
  include Her::Model
  include Powernode::Encryption

  has_many :nodes
  has_many :notifications
  has_many :operations
  has_many :providers

  parse_root_in_json true

  def do_maintenance(job = nil)
    operations.select { |o| !o.async? }.each do |operation|
      if operation.pending? && (!operation.scheduled_at || Time.parse(operation.scheduled_at) < Time.now)
        operation.running!
        operable = operation.send(operation.operable_type.underscore)
        operable.send('do_' + operation.command, operation.to_hash) if operable.respond_to?('do_' + operation.command)
        operation.complete!
      elsif operation.running?
        notifications.create(category: :error, summary: "#{operation.description} failed unexpectedly!")
        operation.failed!
      elsif operation.failed?
        operation.complete!
      end
    end
    running_jobs = {}
    operations.select { |o| o.async? }.each do |operation|
      if operation.pending? && (!operation.scheduled_at || Time.parse(operation.scheduled_at) < Time.now)
        operation.running! if running_jobs[operation.id] = Agent.perform_async(operation.to_hash.merge({ unique: UUIDTools::UUID.timestamp_create}))
      elsif operation.running?
        notifications.create(category: :error, summary: "#{operation.description} failed unexpectedly!")
        operation.failed!
      elsif operation.failed?
        operation.complete!
      end
    end
    while running_jobs.size > 0
      running_jobs.keys.each do |operation_id|
        operation = Operation.find(operation_id)
        status = Sidekiq::Status::status(running_jobs[operation_id])
        case status
        when :complete
          running_jobs.delete(operation_id)
          operation.complete!
        when :failed, nil
          running_jobs.delete(operation_id)
          operation.failed!
        end
        sleep 1
      end
    end
    command = 'maintenance'
    providers.each do |provider|
      Agent.perform_async({ command: command, operable_type: 'provider', operable_id: provider.id })
    end
    nodes.each do |node|
      Agent.perform_async({ command: command, operable_type: 'node', operable_id: node.id })
    end
  end
end
