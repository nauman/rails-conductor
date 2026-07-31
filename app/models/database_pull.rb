# Pulls a PostgreSQL database from a remote server down to the Conductor host
# (a `pg_dump` over SSH, downloaded via SCP) and optionally restores it into a
# local Postgres database. Mirrors the streaming-run pattern of ScriptRun.
class DatabasePull < ApplicationRecord
  STATUSES = %w[pending running success failed].freeze

  belongs_to :server
  belongs_to :app, optional: true
  belongs_to :user, optional: true
  belongs_to :organization, optional: true

  # SB-001. Both of these reach a shell, and `restore_target` names a database
  # that gets DROPPED — so their shape is a security boundary, not a nicety.
  #
  # An environment variable name, and nothing else: `$#{var}` is interpolated
  # into a remote command, so anything outside this set is command injection on
  # the source server.
  ENV_VAR_NAME = /\A[A-Z][A-Z0-9_]*\z/

  # A plain PostgreSQL identifier. Reserved names are refused outright below.
  DB_NAME = /\A[a-z_][a-z0-9_]*\z/

  # Databases that must never be dropped, whatever a caller asks for.
  PROTECTED_DATABASES = %w[postgres template0 template1].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :source_database_url_var, presence: true,
            format: { with: ENV_VAR_NAME,
                      message: "must be an environment variable name (A-Z, digits, underscore)" }
  validates :restore_target, format: { with: DB_NAME, message: "must be a plain database name" },
            allow_blank: true
  validate :restore_target_is_allowed

  # The databases a restore may overwrite. Configured explicitly, because the
  # safe answer is not derivable: this host's Postgres may hold anything.
  #   DATABASE_PULL_RESTORE_TARGETS=app_one_development,app_two_development
  def self.allowed_restore_targets
    ENV.fetch("DATABASE_PULL_RESTORE_TARGETS", "").split(",").map(&:strip).reject(&:blank?) -
      PROTECTED_DATABASES - conductor_own_databases
  end

  # Never let a pull drop the control plane's own databases — primary, queue,
  # cache and cable all resolve from this app's configuration.
  def self.conductor_own_databases
    ActiveRecord::Base.configurations
                      .configs_for(env_name: Rails.env)
                      .filter_map { |c| c.configuration_hash[:database] }
  rescue StandardError
    []
  end

  scope :recent, -> { order(created_at: :desc) }

  private

  def restore_target_is_allowed
    return if restore_target.blank?
    return if restore_target_allowed?

    errors.add(:restore_target,
               "is not an allowed restore target. Add it to DATABASE_PULL_RESTORE_TARGETS " \
               "(Conductor's own databases and postgres/template0/template1 can never be targets).")
  end

  public

  # Re-checked at execution time as well (DatabasePullService), so a row inserted
  # by raw SQL or an older code path cannot reach dropdb.
  def restore_target_allowed?
    restore_target.present? &&
      restore_target.match?(DB_NAME) &&
      !PROTECTED_DATABASES.include?(restore_target) &&
      self.class.allowed_restore_targets.include?(restore_target)
  end

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
