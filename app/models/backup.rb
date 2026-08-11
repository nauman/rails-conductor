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
  # bucket_name reaches a SHELL on the managed box — the dump path, stat, rm -f,
  # the S3 URI, and the upload confirmation — and it is editable by owners AND
  # editors. It carried only a presence check while six other operator-editable
  # fields were locked down on 2026-08-01; this one was missed.
  #
  # The rule is S3/R2's own naming rule, which happens to be shell-safe: 3–63
  # chars, lowercase alphanumerics, dots and hyphens. Anything a real bucket can
  # be called still validates, so this rejects nothing legitimate.
  BUCKET_NAME = /\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/
  validates :bucket_name, presence: true,
                          format: { with: BUCKET_NAME,
                                    message: "must be 3-63 chars, lowercase letters, numbers, dots or hyphens" }
  validates :status, inclusion: { in: STATUSES }
  validates :schedule, inclusion: { in: SCHEDULES }, allow_blank: true
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }

  # WHERE A DUMP LANDS IN THE BUCKET.
  #
  # This used to be `<bucket_name>_<timestamp>.sql.gz`, i.e. named after the
  # DESTINATION. With one shared bucket for the whole fleet that meant every app
  # wrote objects called `acme-backups_<ts>.sql.gz`: you could not tell whose
  # dump you were holding, and — because the stamp is second-resolution and every
  # "daily" backup fires in the same minute — two apps finishing together wrote
  # the SAME key. R2 PUT is last-write-wins, so one app's backup replaced
  # another's, silently.
  #
  # An app slug is validated (it already reaches container names and systemd
  # units). A server fallback covers a box-level backup with no app. The result
  # is checked against SAFE_PREFIX anyway, because this string is interpolated
  # into `aws s3 cp`, `aws s3 ls` and a /tmp path.
  SAFE_PREFIX = /\A[a-z0-9][a-z0-9\-]*\z/

  def object_prefix
    raw = app&.slug.presence || "server-#{server_id}"
    prefix = raw.to_s.downcase.tr("_", "-")
    raise ArgumentError, "unsafe backup prefix: #{raw.inspect}" unless prefix.match?(SAFE_PREFIX)

    prefix
  end

  # Foldered so the bucket stays browsable and a per-app lifecycle rule is
  # possible later — retention is currently a promise nothing enforces.
  def object_key_for(at = Time.current)
    "#{object_prefix}/#{object_prefix}_#{at.strftime('%Y%m%d_%H%M%S')}.sql.gz"
  end

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

  # THE VERDICT IS THE RESTORE.
  #
  # These two used to be independent: intellectaco sat at `status: "completed"`
  # with `verification_status: "failed"` — its dump restored to zero tables and
  # the row still said the backup had succeeded. `status` is what the list, the
  # coverage count and an operator's glance actually read, so the evidence has to
  # move it. A dump that cannot restore is not a completed backup.
  def record_restore_failure!(note, checked_at: Time.current)
    attrs = { verification_status: "failed", verified_at: checked_at,
              verification_note: note.to_s.truncate(255) }

    # Verification runs long after the upload. If a NEWER run has succeeded since
    # the dump under test, demoting would report the old dump's problem as the
    # current state. Only demote when this verdict is about the current run.
    attrs[:status] = "failed" if last_run_at.blank? || last_run_at <= checked_at

    update!(attrs)
  end

  def record_restore_success!(note:, checked_at: Time.current)
    update!(verification_status: "verified", verified_at: checked_at,
            verification_note: note.to_s.truncate(255))
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
