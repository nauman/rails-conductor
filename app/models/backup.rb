class Backup < ApplicationRecord
  PROVIDERS = %w[cloudflare_r2 aws_s3 backblaze_b2 local].freeze
  STATUSES = %w[pending running completed failed warning].freeze
  SCHEDULES = %w[hourly daily weekly monthly].freeze

  belongs_to :server, optional: true
  belongs_to :app, optional: true
  belongs_to :credential, optional: true

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :bucket_name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :schedule, inclusion: { in: SCHEDULES }, allow_blank: true

  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :pending, -> { where(status: "pending") }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :enabled, -> { where(enabled: true) }
  scope :due, -> { enabled.where("next_run_at <= ?", Time.current) }

  after_save :calculate_next_run, if: -> { saved_change_to_enabled? || saved_change_to_schedule? }

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

  def mark_completed!
    update!(
      status: "completed",
      completed_at: Time.current,
      last_run_at: Time.current
    )
    calculate_next_run
  end

  def mark_failed!
    update!(status: "failed", last_run_at: Time.current)
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
