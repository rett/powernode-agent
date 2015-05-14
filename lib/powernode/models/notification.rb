class Notification
  include Her::Model
  attributes :category, :content, :summary
  parse_root_in_json true

  CATEGORIES = %w[alert error warning information notice]

  belongs_to :account
end
