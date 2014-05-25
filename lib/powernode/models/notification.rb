class Notification
  include PowerNode::ModelExtensions

  CATEGORIES = %w[alert error warning information notice]

  def initialize(category, summary, content = '')
    raise PowerNode::InvalidArgumentError unless Notification::CATEGORIES.include?(category.to_s)
    @category = category.to_s
    @summary = summary.to_s
    @content = content.to_s
  end

  attr_accessor :category, :content, :summary
end
