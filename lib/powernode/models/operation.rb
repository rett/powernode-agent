class Operation
  include Her::Model
  parse_root_in_json true

  belongs_to :account

  attributes :events

  STATUSES = %w[abort complete failed pending running]

  Operation::STATUSES.each do |s|
    define_method(s + '?') do
      self.status == s
    end
  end

  def initialize(attributes = {})
    super(attributes)
    self.events ||= []
    define_singleton_method operable_type.underscore.to_sym do
      operable_type.classify.constantize.find(operable_id)
    end
  end

  def add_event!(variety, details)
    self.events << { details: details, variety: variety, unique: UUIDTools::UUID.timestamp_create.to_s }
    self.save
  end

  def async
    options['async'] ? true : false
  end
  alias async? async

  def complete!
    self.progress = 100
    self.status = 'complete'
    self.save
  end

  def failed!(details = nil)
    self.events << { details: details, variety: :danger } if details
    self.status = 'failed'
    self.save
  end

  def running!
    self.status = 'running'
    self.save
  end

  def progress!(p)
    self.progress = p
    self.save
  end

  def to_hash
    { 'command' => command,
      'events' => events,
      'id' => id,
      'operable_id' => operable_id,
      'operable_type' => operable_type,
      'options' => options }
  end
end
