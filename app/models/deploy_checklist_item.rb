class DeployChecklistItem < ApplicationRecord
  belongs_to :app

  validates :content, presence: true

  scope :ordered, -> { order(:position) }

  before_validation :assign_position, on: :create

  def check!(user: nil)
    update!(done: true, done_at: Time.current)
  end

  def uncheck!
    update!(done: false, done_at: nil)
  end

  private

  # Append to the end of the app's checklist unless a position was set.
  def assign_position
    return if position.to_i.positive?
    return unless app

    self.position = (app.deploy_checklist_items.maximum(:position) || 0) + 1
  end
end
