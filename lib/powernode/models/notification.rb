class Notification
  TYPES = [:alert, :error, :information, :notice, :warning]

  def initialize(params = {})
    raise PowerNode::HashRequiredError unless params.is_a?(Hash)
    @id ||= UUIDTools::UUID.timestamp_create.to_s
    @created_at = UUIDTools::UUID.parse(@id).timestamp
    @messages = params
  end

  def keys
    @messages.keys
  end

  def messages
    @messages
  end

  TYPES.each do |type|
    define_method(type) do
      @messages[type]
    end
    define_method("#{type}=".to_sym) do |message|
      @messages[type] = message
    end
  end

  def to_hash
    Hash[instance_variables.map { |name| [name.to_s.delete("@"), instance_variable_get(name)] } ]
  end

  def to_json(*a)
    to_hash.to_json(a)
  end
end
