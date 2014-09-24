class ProviderNetworkSubnet
  include Her::Model

  parse_root_in_json true

  belongs_to :provider_network
  has_many :nodes
end
