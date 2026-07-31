class Deployment < ApplicationRecord
  # "blocked" = a deploy attempt the preflight gate refused (recorded, not run) so
  # the intent isn't lost — it is NOT an in_progress state (see the scope + index).
  STATUSES = %w[pending building deploying succeeded failed cancelled blocked].freeze

  belongs_to :app
  belongs_to :server, optional: true
  belongs_to :user, optional: true

  # Coarse blame for a failure, so the UI can say "this one wasn't your code".
  #   app_code       — the app failed to build, migrate, or boot
  #   infrastructure — Conductor, the host, the registry, or the network failed
  #   preflight      — refused before running (a gate said no)
  # Optional: rows predating this, and successful deploys, carry nothing.
  CAUSE_CLASSES = %w[app_code infrastructure preflight].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :cause_class, inclusion: { in: CAUSE_CLASSES }, allow_blank: true

  scope :recent, -> { order(created_at: :desc) }
  scope :successful, -> { where(status: "succeeded") }
  scope :failed, -> { where(status: "failed") }
  scope :in_progress, -> { where(status: %w[pending building deploying]) }
  scope :blocked, -> { where(status: "blocked") }
  # Successful deploys that shipped a rollback-able release (a version tag Kamal
  # can boot again on the host), newest first.
  scope :rollbackable, -> { successful.where.not(release_version: [ nil, "" ]).recent }

  # Rollback targets valid for the app AS IT IS NOW. A release shipped under a
  # different runtime is not a target: a Kamal-era version names no local docker
  # image, and offering it would fail at best and mislead at worst. Rows from
  # before this column existed are backfilled, so nil means "unknown" and is
  # excluded rather than assumed compatible.
  scope :rollbackable_for, ->(app) { rollbackable.where(deploy_method: app.deploy_method) }

  def rollback?
    kind == "rollback"
  end

  # The release identifier this deployment shipped — what a rollback targets.
  # Kamal's version is the deployed sha; fall back to it if release_version is
  # unset (deploys from before the column existed).
  def target_version
    release_version.presence || commit_sha.presence
  end

  # Can the app be rolled back TO this deployment's release? It must have shipped
  # a version and not be the release currently running (the latest success).
  # Backend support (Kamal-only for now) is gated by the caller.
  def rollback_target?
    return false unless succeeded? && target_version.present?

    app.deployments.successful.order(:created_at).last&.id != id
  end

  # The parsed preflight blockers captured when this deploy was blocked or forced.
  def preflight_blockers
    return [] if preflight_snapshot.blank?
    JSON.parse(preflight_snapshot)
  rescue JSON::ParserError
    []
  end

  # Live deploy status: push a Turbo Stream replace of the status badge whenever
  # the status changes (building → deploying → succeeded/failed), so the
  # deployment page updates without a reload. Subscribe with turbo_stream_from.
  after_update_commit :broadcast_status_badge, if: :saved_change_to_status?
  # A deployment's status IS the app's deploy health, so the fleet row is stale the
  # moment this changes — on create (a deploy starting flips the row to "deploying")
  # and on every status change after.
  #
  # ONE callback, not after_create_commit + after_update_commit: registering the same
  # method twice makes the second registration replace the first, so the create
  # broadcast silently never fired. Caught by a test that expected a broadcast when a
  # deploy starts.
  # Two registrations, two DIFFERENT method names on purpose: registering the same
  # method for create and update makes the second replace the first, and the create
  # broadcast silently never fires (a test caught exactly that).
  after_create_commit :broadcast_dashboard_app_row_on_create
  after_update_commit :broadcast_dashboard_app_row, if: :saved_change_to_status?

  def broadcast_dashboard_app_row_on_create = broadcast_dashboard_app_row

  def broadcast_dashboard_app_row
    org = app&.organization
    return unless org

    broadcast_replace_to(
      org, :dashboard,
      target: ActionView::RecordIdentifier.dom_id(app, :dashboard_row),
      partial: "dashboard/app_row", locals: { app: app.reload }
    )
  end

  def broadcast_status_badge
    broadcast_replace_to self,
      target: ActionView::RecordIdentifier.dom_id(self, :status_badge),
      partial: "deployments/status_badge", locals: { deployment: self }
  end

  def pending?
    status == "pending"
  end

  def building?
    status == "building"
  end

  def deploying?
    status == "deploying"
  end

  def succeeded?
    status == "succeeded"
  end

  def failed?
    status == "failed"
  end

  def infrastructure_failure? = cause_class == "infrastructure"
  def app_code_failure?       = cause_class == "app_code"

  def in_progress?
    %w[pending building deploying].include?(status)
  end

  def duration
    return nil unless started_at
    end_time = completed_at || Time.current
    (end_time - started_at).to_i
  end

  def formatted_duration
    return "—" unless duration
    if duration < 60
      "#{duration}s"
    else
      "#{duration / 60}m #{duration % 60}s"
    end
  end

  def append_log(message)
    timestamp = Time.current.strftime("%H:%M:%S")
    new_line = "[#{timestamp}] #{message}\n"
    update!(log: (log || "") + new_line)
  end

  # The actionable "why" a failed deploy failed: the last ERROR: line appended to
  # the log, with the timestamp + "ERROR:" prefix stripped. Lets callers (the MCP
  # situation read, alerts) surface the reason inline instead of making the agent
  # fetch and parse the whole log. Nil if there's no recorded error line.
  def failure_reason
    return nil if log.blank?

    line = log.lines.reverse_each.find { |l| l.include?("ERROR:") }
    return nil unless line

    line.sub(/\A\[[^\]]*\]\s*/, "").sub(/\AERROR:\s*/, "").strip.presence
  end

  def start!
    update!(status: "building", started_at: Time.current)
  end

  def mark_deploying!
    update!(status: "deploying")
  end

  def succeed!
    update!(status: "succeeded", completed_at: Time.current)
    app.update!(status: "running", deployed_at: Time.current)
  end

  def fail!(error_message = nil, cause: nil)
    append_log("ERROR: #{error_message}") if error_message
    update!(status: "failed", completed_at: Time.current,
            cause_class: cause || classify_failure(error_message))
    app.update!(status: "failed")

    # Send notification
    AlertMailer.deployment_failed(self).deliver_later
  end

  # Reap a stuck deployment: flip it to the terminal `cancelled` state so it leaves
  # the one-active-deploy-per-app index and the app can deploy again. Used when a
  # deploy's driver process is gone (e.g. a job-retry race orphaned it at
  # "deploying"). Does NOT touch app.status — a cancel is not a failure of the app.
  def cancel!
    update!(status: "cancelled", completed_at: Time.current)
  end

  private

  # Coarse blame from the failure text. Deliberately conservative: only signatures
  # we've actually seen in production are classified, and anything unrecognised
  # stays nil rather than guessing "your code" — a wrong accusation costs more
  # than a blank field.
  #
  # Every pattern here comes from a real failure:
  #   ENOTTY / no such identity / Permission denied (publickey  — the ssh identity bug
  #   dial-stdio / buildx / docker system                       — the shared-builder bug
  #   Connection refused|timed out|No route to host             — the target was unreachable
  #   registry / unauthorized: authentication required          — registry auth
  INFRASTRUCTURE_SIGNATURES = Regexp.union(
    /ENOTTY/i, /no such identity/i, /Permission denied \(publickey/i,
    /dial-stdio/i, /buildx/i, /docker system/i,
    /Connection refused/i, /Connection timed out/i, /No route to host/i,
    /unauthorized: authentication required/i, /denied: requested access/i
  ).freeze

  def classify_failure(message)
    text = "#{message}\n#{log}"
    return "infrastructure" if text.match?(INFRASTRUCTURE_SIGNATURES)

    nil
  end
end
