class Conversation < ApplicationRecord
  STATUSES = %w[active archived].freeze

  belongs_to :user
  has_many :messages, -> { order(sequence: :asc) }, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  scope :active,   -> { where(status: 'active') }
  scope :archived, -> { where(status: 'archived') }
  scope :recent,   -> { order(created_at: :desc) }

  def active?   = status == 'active'
  def archived? = status == 'archived'

  def archive!
    update!(status: 'archived')
  end

  # Returns the message history formatted for the Anthropic API.
  # Groups consecutive user messages and merges tool results into
  # the turn that requested them.
  def messages_for_api
    messages.select(&:complete?).map do |msg|
      { role: msg.role, content: msg.content.to_s }
    end
  end

  def auto_title_from(text)
    return if title.present?
    update!(title: text.to_s.truncate(60))
  end
end
