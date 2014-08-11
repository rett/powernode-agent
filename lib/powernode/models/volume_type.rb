class VolumeType
  include Her::Model

  has_many :volumes

  parse_root_in_json true
end
