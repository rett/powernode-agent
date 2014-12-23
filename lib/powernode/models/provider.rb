class Provider
  include Her::Model

  has_many :provider_connections
  has_many :provider_regions

  parse_root_in_json true
end
