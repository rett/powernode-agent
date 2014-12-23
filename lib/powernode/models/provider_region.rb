class ProviderRegion
  include Her::Model

  parse_root_in_json true

  belongs_to :provider
  has_many :provider_instance_types
  has_many :provider_network_subnets
end
