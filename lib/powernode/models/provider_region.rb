class ProviderRegion
  include Her::Model
  parse_root_in_json true

  belongs_to :account
  belongs_to :provider
end
