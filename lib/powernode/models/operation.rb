class Operation
  include Her::Model

  STATUSES = %w[complete failed pending running]

  belongs_to :node
  belongs_to :node_instance
  belongs_to :node_module
  belongs_to :volume

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
end
