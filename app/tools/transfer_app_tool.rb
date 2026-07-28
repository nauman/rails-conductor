# Execute an app transfer (or clone) to another server — the invocable end of
# spec 26. Destructive + outward-facing (redeploys, copies the DB, repoints DNS,
# drains the source), so it is CONFIRM-GATED: a bare call returns the dry-run
# plan and does nothing; only `confirm: true` creates the AppTransfer and enqueues
# AppTransferJob. Org boundary is enforced by AppTransferPlan / AppTransfer /
# AppTransferRunner (AppTransferOrgBoundary) — this tool never crosses an org.
class TransferAppTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    target = find_target(input)
    return Result.fail("Target server not found: #{input['target_server_id'] || input['target_server_name']}") unless target

    mode = %w[transfer clone].include?(input["mode"]) ? input["mode"] : "transfer"

    # Preview (dry-run) unless explicitly confirmed — never mutate on a bare call.
    unless truthy?(input["confirm"])
      plan = AppTransferPlan.new(app: app, target_server: target).call
      return Result.ok(plan.to_h.merge(
        status: "confirmation_required", action_taken: false, mode: mode,
        message: "This will #{mode} #{app.name} #{app.server&.name} → #{target.name}: redeploy, copy the DB, " \
                 "publish the edge, repoint DNS#{mode == 'transfer' ? ', then drain the source' : ' (source stays live)'}. " \
                 "Re-call with confirm: true, credential_id (R2/S3 for the DB copy) and bucket.",
        _organization: app.organization
      ))
    end

    credential = app.organization.credentials.find_by(id: input["credential_id"])
    return Result.fail("transfer (confirm) needs credential_id — an object-store credential for the DB copy.") unless credential
    bucket = input["bucket"].presence
    return Result.fail("transfer (confirm) needs a bucket for the DB copy.") unless bucket

    transfer = AppTransfer.create!(
      app: app, organization: app.organization,
      source_server: app.server, target_server: target, mode: mode
    )
    AppTransferJob.perform_later(transfer.id, credential_id: credential.id, bucket: bucket)

    Result.ok(
      transfer_id: transfer.id, status: "running", mode: mode,
      from: app.server&.name, to: target.name,
      message: "#{mode.capitalize} of #{app.name} to #{target.name} started (transfer ##{transfer.id}).",
      verify: "poll AppTransfer ##{transfer.id} for phase/status",
      _organization: app.organization
    )
  rescue AppTransferPlan::InvalidTarget => e
    Result.fail(e.message) # covers cross-org (enforced with error: InvalidTarget) + bad target
  rescue ActiveRecord::RecordInvalid => e
    Result.fail("Transfer refused: #{e.message}")
  end

  private

  def find_target(input)
    if input["target_server_id"].present?
      visible_servers.find_by(id: input["target_server_id"])
    elsif input["target_server_name"].present?
      visible_servers.find_by(name: input["target_server_name"])
    end
  end

  def truthy?(value) = [ true, "true", "1", 1 ].include?(value)
end
