class ProviderNetwork
  include Her::Model
  parse_root_in_json true

  belongs_to :account
  has_many :provider_network_subnets
end
