class ToolExecution < ApplicationRecord
  STATUSES = %w[pending running success failed].freeze

  belongs_to :message

  validates :tool_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent,  -> { order(created_at: :desc) }
  scope :pending, -> { where(status: 'pending') }
  scope :running, -> { where(status: 'running') }
  scope :done,    -> { where(status: %w[success failed]) }

  def pending?  = status == 'pending'
  def running?  = status == 'running'
  def success?  = status == 'success'
  def failed?   = status == 'failed'
  def done?     = success? || failed?

  def duration
    return nil unless started_at && completed_at
    (completed_at - started_at).round(2)
  end

  def start!
    update!(status: 'running', started_at: Time.current)
  end

  def finish!(output:, success:)
    update!(
      tool_output: output,
      status: success ? 'success' : 'failed',
      completed_at: Time.current
    )
  end
end
