class Notification
  include Her::Model

  CATEGORIES = %w[alert error warning information notice]

  belongs_to :account

  attributes :category, :content, :summary
end
