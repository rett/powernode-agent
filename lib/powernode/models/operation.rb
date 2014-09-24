class Operation
  include Her::Model

  belongs_to :account

  STATUSES = %w[complete failed pending running]

  parse_root_in_json true

  Operation::STATUSES.each do |s|
    define_method(s + '?') do
      self.status == s
    end
    define_method(s + '!') do
      self.status = s
      self.save
    end
  end

  def initialize(attributes = {})
    super(attributes)
    define_singleton_method operable_type.underscore.to_sym do
      operable_type.classify.constantize.find(operable_id)
    end
  end

  def async
    options['async'] ? true : false
  end
  alias async? async

  def to_hash
    { command: command,
      id: id,
      operable_id: operable_id,
      operable_type: operable_type,
      options: options }
  end
end
