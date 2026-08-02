class Backup < ApplicationRecord
  include OrganizationConsistency
  validate_same_organization :server, :app, :credential
  # S3-compatible destinations (+ local). Per-vendor endpoint/region live in
  # BackupVendors; DatabaseBackup builds one uniform upload from it.
  PROVIDERS = %w[aws_s3 cloudflare_r2 wasabi backblaze_b2 do_spaces minio local].freeze
  STATUSES = %w[pending running completed failed warning].freeze
  SCHEDULES = %w[hourly daily weekly monthly].freeze
  # Whether a RESTORE has proved this backup, which is a different question from whether
  # the dump uploaded (design B2).
  VERIFICATION_STATUSES = %w[never_tested verified failed].freeze

  belongs_to :organization, optional: true
  belongs_to :server, optional: true
  belongs_to :app, optional: true
  belongs_to :credential, optional: true
  # Per-attempt history. The columns on this row only ever describe the LATEST
  # run, which is why a skipped night used to leave no evidence at all.
  has_many :runs, class_name: "BackupRun", dependent: :destroy

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :bucket_name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :schedule, inclusion: { in: SCHEDULES }, allow_blank: true
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }

  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :pending, -> { where(status: "pending") }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :enabled, -> { where(enabled: true) }
  # Due AND not already running. Without the second half, a backup whose process
  # died mid-run stays "running" with next_run_at in the past, so the dispatcher
  # re-enqueues it EVERY MINUTE — a stampede that exhausted SSH on the box and
  # failed every other backup with "connection closed by remote host".
  scope :due, -> { enabled.where("next_run_at <= ?", Time.current).where.not(status: "running") }

  # A run that has been "running" longer than this had its process die — nothing
  # legitimate takes this long, and the row must be released or it blocks its own
  # schedule forever.
  STUCK_AFTER = 30.minutes

  scope :stuck, lambda {
    enabled.where(status: "running").where("last_run_at IS NULL OR last_run_at < ?", STUCK_AFTER.ago)
  }

  after_save :calculate_next_run, if: -> { saved_change_to_enabled? || saved_change_to_schedule? }

  # One word for "how safe is this really". Ordered by what an operator needs to hear
  # first — a schedule that has stopped running beats a verification from last week,
  # because the newest data isn't backed up at all.
  def verification_state
    return :never_run if last_run_at.blank?
    return :restore_failed if verification_status == "failed"
    return :stale if overdue?
    return :verified if verification_status == "verified"

    :unverified
  end

  # Has the promise been kept? Measured from the LAST RUN against the schedule, not from
  # next_run_at — a scheduler that stopped writing next_run_at would otherwise look fine
  # forever, which is the failure most likely to go unnoticed. Two intervals of grace, so a
  # single missed night is not an alarm.
  SCHEDULE_INTERVAL = { "hourly" => 1.hour, "daily" => 1.day, "weekly" => 1.week, "monthly" => 30.days }.freeze

  # Its process died: still flagged "running" long after anything legitimate
  # would have finished. The reaper releases these, but they are worth SEEING —
  # a backup that keeps dying is not a backup.
  def stuck_running?
    status == "running" && (last_run_at.nil? || last_run_at < STUCK_AFTER.ago)
  end

  def overdue?
    return false unless enabled? && last_run_at.present?

    interval = SCHEDULE_INTERVAL[schedule] || 1.day
    last_run_at < (interval * 2).ago
  end

  # Proved by an actual restore. Deliberately NOT true for :unverified — the whole point
  # of the distinction is that an untested dump doesn't get to look green.
  def proven? = verification_state == :verified

  # Worth an incident: the dump exists and does not work.
  def alarming? = verification_state == :restore_failed

  def formatted_size
    return "0 B" if size_bytes.zero?

    units = %w[B KB MB GB TB]
    size = size_bytes.to_f
    unit_index = 0

    while size >= 1024 && unit_index < units.length - 1
      size /= 1024
      unit_index += 1
    end

    "#{size.round(1)} #{units[unit_index]}"
  end

  def time_ago
    return "—" unless completed_at

    seconds = Time.current - completed_at
    case seconds
    when 0..59 then "just now"
    when 60..3599 then "#{(seconds / 60).to_i} min ago"
    when 3600..86399 then "#{(seconds / 3600).to_i} hours ago"
    else "#{(seconds / 86400).to_i} days ago"
    end
  end

  def retention_display
    "#{retention_days} days"
  end

  def source_name
    app&.name || server&.name || "—"
  end

  def schedule_display
    return "Manual" unless enabled?
    schedule&.titleize || "Daily"
  end

  def next_run_display
    return "—" unless enabled? && next_run_at
    if next_run_at < Time.current
      "Overdue"
    elsif next_run_at < 1.hour.from_now
      "Soon"
    else
      next_run_at.strftime("%b %d, %H:%M")
    end
  end

  def dispatch_overdue?
    return false unless enabled? && next_run_at.present?

    next_run_at < dispatch_grace_period.ago
  end

  # Record that this schedule was enqueued. Written BEFORE any work happens, so a
  # job that is lost between the dispatcher and a worker leaves a row that stops
  # at "dispatched" — the trace that was missing.
  def record_dispatch!(trigger:)
    runs.create!(trigger: trigger, status: "dispatched", dispatched_at: Time.current)
  end

  # Stamp last_run_at at the START, not at the outcome.
  #
  # It used to be written only on failure, which inverted every signal built on
  # it: `overdue?` called a nightly-succeeding backup stale, and `Backup.stuck`
  # matched a healthy run the moment it began. "When did this last run" is a
  # question about the attempt, not about whether the attempt worked.
  def begin_run!
    update!(status: "running", last_run_at: Time.current)
  end

  def mark_completed!(size_bytes: nil)
    attrs = {
      status: "completed",
      completed_at: Time.current,
      last_run_at: Time.current
    }
    attrs[:size_bytes] = size_bytes unless size_bytes.nil?

    update!(attrs)
    calculate_next_run
  end

  def mark_failed!
    update!(status: "failed", last_run_at: Time.current)
    calculate_next_run
  end

  # Release a run whose process died. Recorded as failed — it did not succeed,
  # and a silent reset would hide that backups are not being taken.
  def reap_stuck!
    update!(status: "failed", last_run_at: last_run_at || Time.current)
    calculate_next_run
  end

  def calculate_next_run
    return update!(next_run_at: nil) unless enabled?

    next_time = case schedule
    when "hourly"
      1.hour.from_now.beginning_of_hour
    when "daily"
      1.day.from_now.change(hour: 3) # 3 AM
    when "weekly"
      1.week.from_now.beginning_of_week.change(hour: 3)
    when "monthly"
      1.month.from_now.beginning_of_month.change(hour: 3)
    else
      1.day.from_now.change(hour: 3)
    end

    update!(next_run_at: next_time)
  end

  private

  def dispatch_grace_period
    case schedule
    when "hourly"
      15.minutes
    when "daily"
      2.hours
    when "weekly", "monthly"
      6.hours
    else
      1.hour
    end
  end
end
