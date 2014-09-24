class ProviderVolumeSnapshot
  include Her::Model

  belongs_to :provider_volume

  parse_root_in_json true
end
