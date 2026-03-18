class Message < ApplicationRecord
  ROLES    = %w[user assistant].freeze
  STATUSES = %w[pending streaming complete error].freeze

  belongs_to :conversation
  has_many :tool_executions, dependent: :destroy

  validates :role,   inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }

  before_create :set_sequence

  scope :complete,   -> { where(status: 'complete') }
  scope :user_msgs,  -> { where(role: 'user') }
  scope :assistant_msgs, -> { where(role: 'assistant') }

  def user?      = role == 'user'
  def assistant? = role == 'assistant'

  def pending?   = status == 'pending'
  def streaming? = status == 'streaming'
  def complete?  = status == 'complete'
  def error?     = status == 'error'

  # Called by ProcessMessageJob — delegates to ConversationProcessor.
  def process_now
    ConversationProcessor.new(message: self).process
  end

  def mark_streaming!
    update!(status: 'streaming')
    broadcast_update_to conversation, target: dom_id, partial: 'messages/message', locals: { message: self }
  end

  def mark_complete!(content)
    update!(content: content, status: 'complete')
    broadcast_update_to conversation, target: dom_id, partial: 'messages/message', locals: { message: self }
  end

  def mark_error!(text)
    update!(content: text, status: 'error')
    broadcast_update_to conversation, target: dom_id, partial: 'messages/message', locals: { message: self }
  end

  def dom_id
    "message_#{id}"
  end

  private

  def set_sequence
    last = conversation.messages.maximum(:sequence) || -1
    self.sequence = last + 1
  end
end
