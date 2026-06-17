class CronJob < ApplicationRecord
  STATUSES = %w[enabled disabled].freeze

  belongs_to :organization
  belongs_to :server

  validates :name, :command, :schedule, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :schedule_resolves_to_cron

  before_validation :resolve_cron_expression

  scope :enabled, -> { where(status: "enabled") }

  def enabled?
    status == "enabled"
  end

  # Stable identifier for the server's managed crontab block.
  def crontab_id
    "cron-#{id}"
  end

  # Write (or rewrite) this job's managed block into the server's crontab.
  # `client:` is injectable for tests.
  def install!(client: nil)
    (client || CrontabClient.new(server)).upsert_job(
      id: crontab_id, name: name, cron_expression: cron_expression,
      command: command, enabled: enabled?
    )
  end

  # Remove this job's managed block from the server's crontab.
  def uninstall!(client: nil)
    (client || CrontabClient.new(server)).remove_job(id: crontab_id)
  end

  private

  def resolve_cron_expression
    return if schedule.blank?

    self.cron_expression = CronSchedule.to_cron(schedule)
  rescue CronSchedule::Error
    # Leave cron_expression unset; schedule_resolves_to_cron adds the error.
  end

  def schedule_resolves_to_cron
    return if schedule.blank?
    return if cron_expression.present?

    errors.add(:schedule, "is not a valid schedule (try \"every 2 hours\" or \"0 3 * * *\")")
  end
end
