class ScriptRun < ApplicationRecord
  STATUSES = %w[pending running success failed].freeze

  belongs_to :server
  belongs_to :script
  belongs_to :user, optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def pending?  = status == 'pending'
  def running?  = status == 'running'
  def success?  = status == 'success'
  def failed?   = status == 'failed'
  def done?     = success? || failed?

  def append_log(line)
    self.log = "#{log}#{line}"
    update_columns(log: self.log)
    ActionCable.server.broadcast("script_run_#{id}", { line: line })
  end

  def start!
    update!(status: 'running', started_at: Time.current)
    ActionCable.server.broadcast("script_run_#{id}", { status: 'running' })
  end

  def finish!(success:)
    final = success ? 'success' : 'failed'
    update!(status: final, completed_at: Time.current)
    ActionCable.server.broadcast("script_run_#{id}", { status: final, done: true })
  end

  def duration
    return nil unless started_at && completed_at
    (completed_at - started_at).round
  end
end
