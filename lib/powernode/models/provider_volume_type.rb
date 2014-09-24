class ProviderVolumeType
  include Her::Model

  has_many :provider_volumes

  parse_root_in_json true
end
