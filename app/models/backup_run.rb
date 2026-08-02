# One attempt at a backup.
#
# The `backups` row carries only the LATEST state — one status, one
# completed_at, one size. That made an ordinary operational question
# unanswerable: "did this app back up on the 31st?" had no record to consult,
# because a successful run overwrote the previous one and a dispatch that never
# executed wrote nothing at all.
#
# The dispatched → running → completed/failed sequence matters. A row that stops
# at `dispatched` is a job that was enqueued and then lost — the failure mode
# that leaves no trace today, because a job that never starts also never fails.
class BackupRun < ApplicationRecord
  STATUSES = %w[dispatched running completed failed].freeze
  TRIGGERS = %w[scheduled manual].freeze

  # A backup that has not begun this long after being enqueued is not slow, it is
  # gone: the dispatcher enqueues, and a healthy worker picks the job up in
  # seconds. Generous enough to survive a queue backlog without crying wolf.
  LOST_AFTER = 1.hour

  belongs_to :backup

  validates :status, inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }
  validates :dispatched_at, presence: true

  scope :recent, -> { order(dispatched_at: :desc, id: :desc) }
  scope :succeeded, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }

  # Enqueued, never started. Deliberately NOT "running for too long" — that is
  # stuck, a different diagnosis with a different fix. This one means the job
  # never reached a worker at all.
  scope :lost, -> { where(status: "dispatched").where(dispatched_at: ..LOST_AFTER.ago) }

  def start!
    update!(status: "running", started_at: Time.current)
  end

  def complete!(size_bytes:)
    update!(status: "completed", finished_at: Time.current, size_bytes: size_bytes)
  end

  # The reason is not optional. A failed row with no message tells the next
  # person that something broke and nothing about what.
  def fail!(message)
    update!(status: "failed", finished_at: Time.current, error_message: message.to_s.truncate(500))
  end

  def duration
    return nil unless started_at && finished_at

    finished_at - started_at
  end
end
