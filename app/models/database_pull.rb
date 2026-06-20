# Pulls a PostgreSQL database from a remote server down to the Conductor host
# (a `pg_dump` over SSH, downloaded via SCP) and optionally restores it into a
# local Postgres database. Mirrors the streaming-run pattern of ScriptRun.
class DatabasePull < ApplicationRecord
  STATUSES = %w[pending running success failed].freeze

  belongs_to :server
  belongs_to :app, optional: true
  belongs_to :user, optional: true
  belongs_to :organization, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :source_database_url_var, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def pending? = status == "pending"
  def running? = status == "running"
  def success? = status == "success"
  def failed?  = status == "failed"
  def done?    = success? || failed?

  def restore? = restore_target.present?

  # Streaming log + status broadcasts (consumed by DatabasePullChannel).
  def append_log(line)
    self.log = "#{log}#{line}"
    update_columns(log: self.log)
    ActionCable.server.broadcast("database_pull_#{id}", { line: line })
  end

  def start!
    update!(status: "running", started_at: Time.current)
    ActionCable.server.broadcast("database_pull_#{id}", { status: "running" })
  end

  def finish!(success:)
    final = success ? "success" : "failed"
    update!(status: final, completed_at: Time.current)
    ActionCable.server.broadcast("database_pull_#{id}", { status: final, done: true })
  end

  def duration
    return nil unless started_at && completed_at
    (completed_at - started_at).round
  end

  def formatted_size
    return "—" if size_bytes.to_i.zero?

    units = %w[B KB MB GB TB]
    size = size_bytes.to_f
    i = 0
    while size >= 1024 && i < units.length - 1
      size /= 1024
      i += 1
    end
    "#{size.round(1)} #{units[i]}"
  end

  def source_label
    source_database.presence || source_database_url_var
  end
end
