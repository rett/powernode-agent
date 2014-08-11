class NodeTemplate
  include Her::Model

  belongs_to :node_architecture

  parse_root_in_json true
end
