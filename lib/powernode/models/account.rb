class Account
  include Her::Model
  include Powernode::Encryption

  has_many :nodes
  has_many :node_instances, through: :nodes
  has_many :notifications
  has_many :operations
  has_many :volumes
end
