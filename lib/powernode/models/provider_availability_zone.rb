class ProviderAvailabilityZone
  include Her::Model

  belongs_to :account
  belongs_to :provider_region

  parse_root_in_json true
end
