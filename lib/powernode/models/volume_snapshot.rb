class VolumeSnapshot
  include Her::Model

  belongs_to :volume

  parse_root_in_json true
end
