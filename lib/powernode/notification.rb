class Notification
  def initialize(content, severity = :info)
    @id ||= UUIDTools::UUID.timestamp_create.to_s
    @created_at = Time.now
    @content = content
    @severity = severity
  end

  def class
    @class
  end

  def class=(value)
    @class = value
  end

  def content
    @content
  end

  def content=(value)
    @content = value
  end

  def to_hash
    Hash[instance_variables.map { |name| [name.to_s.delete("@"), instance_variable_get(name)] } ]
  end

  def to_json(*a)
    to_hash.to_json(a)
  end
end
