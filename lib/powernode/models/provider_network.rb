class ProviderNetwork
  include Her::Model

  parse_root_in_json true

  has_many :provider_network_subnets
end
