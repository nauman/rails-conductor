# Runs ResidueDetector out of band and persists the result on the app.
#
# The detector makes several SSH round-trips, so it must never sit on a request
# or inside a deploy — wiring it into DeployPreflight hung the app detail page,
# and on the deploy path an unreachable box would have stalled the deploy on
# connect timeouts. This is the stored-rollup pattern the codebase already uses
# for server audits: the job pays the cost, the fast paths read the result.
class ResidueCheckJob < ApplicationJob
  queue_as :default

  # A stored result older than this is stale enough to be worth saying so rather
  # than presenting as current.
  STALE_AFTER = 12.hours

  def perform(app_id)
    app = App.find_by(id: app_id)
    return unless app&.server

    findings = ResidueDetector.new(app).findings

    app.update_columns(
      residue_findings: findings.map { |f| { "kind" => f.kind, "detail" => f.detail, "remedy" => f.remedy } },
      residue_checked_at: Time.current
    )
  rescue StandardError => e
    # Never let a diagnostic job's failure look like a clean app: record the
    # blindness in the same shape a finding takes.
    app&.update_columns(
      residue_findings: [ { "kind" => "unknown", "detail" => "residue check failed: #{e.message}",
                            "remedy" => "re-run the check once the box is reachable" } ],
      residue_checked_at: Time.current
    )
  end

  # Sweep every app that could carry residue. Scheduled, and safe to run often —
  # it only reads.
  def self.sweep(organization = nil)
    scope = App.where.not(server_id: nil).where.not(deploy_method: "native")
    scope = scope.where(organization: organization) if organization
    scope.find_each { |app| perform_later(app.id) }
  end
end
