# Retire (decommission) an app FROM a box — the invocable end of the decommission
# stage. Discovery-FIRST and destructive, so it is gated the AppTransfer way, but
# stricter: a BARE call runs DecommissionPlan and returns the full discovery
# report (what the box actually looks like) while mutating NOTHING — it persists
# only a dry_run Decommission record capturing the findings for the audit trail.
# `confirm: true` runs DecommissionRunner through the teardown phases, recording
# the audit trail + folding learnings into the runbook.
#
# The box to retire FROM must be named EXPLICITLY (from_server_id/from_server_name)
# — never defaulted — and the tool refuses to retire the app's live home (that
# would orphan it: move it with conductor_app action=transfer first).
class RetireAppTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    server = find_from_server(input)
    unless server
      return Result.fail("Name the box to retire FROM explicitly — pass from_server_id or from_server_name (never defaulted, for safety).")
    end

    if app.server_id == server.id
      return Result.fail(
        "#{app.name}'s home is still #{server.name} — retiring it there would orphan the live app. " \
        "Move it first (conductor_app action=transfer), then retire the old box."
      )
    end

    plan = DecommissionPlan.new(app: app, server: server).call

    return report_only(app, server, plan) unless truthy?(input["confirm"])

    execute(app, server, plan)
  rescue DecommissionPlan::InvalidTarget => e
    Result.fail(e.message)
  end

  private

  # Bare call: the discovery report + a dry_run audit record. Mutates nothing.
  def report_only(app, server, plan)
    report = plan.to_h
    decommission = Decommission.create!(
      app: app, organization: app.organization, server: server,
      dry_run: true, status: "pending", findings: report.to_json
    )
    Result.ok(report.merge(
      status: "report_only", action_taken: false, decommission_id: decommission.id,
      message: "Discovery report for retiring #{app.name} from #{server.name} — nothing was changed. " \
               "Review the findings, then re-call with confirm: true to execute the teardown.",
      _organization: app.organization
    ))
  end

  # Confirmed: run the teardown through the phases, recording the audit trail.
  def execute(app, server, plan)
    decommission = Decommission.create!(
      app: app, organization: app.organization, server: server, dry_run: false, status: "pending"
    )
    DecommissionRunner.new(
      decommission,
      deps: DecommissionRunner::FleetDeps.new(decommission),
      plan: plan
    ).run
    decommission.reload

    Result.ok(
      decommission_id: decommission.id, status: decommission.status,
      from: server.name, phase: decommission.phase,
      findings: decommission.findings_data["findings"],
      log: decommission.log,
      message: retire_message(app, server, decommission),
      _organization: app.organization
    )
  end

  def retire_message(app, server, decommission)
    if decommission.succeeded?
      "Retired #{app.name} from #{server.name} (decommission ##{decommission.id}) — containers, dedicated DB, " \
      "and stale records removed. Learnings folded into the runbook."
    else
      "Decommission ##{decommission.id} of #{app.name} from #{server.name} #{decommission.status} at " \
      "phase #{decommission.phase.inspect}. See the log."
    end
  end

  def find_from_server(input)
    if input["from_server_id"].present?
      visible_servers.find_by(id: input["from_server_id"])
    elsif input["from_server_name"].present?
      visible_servers.find_by(name: input["from_server_name"])
    end
  end

  def truthy?(value) = [ true, "true", "1", 1 ].include?(value)
end
