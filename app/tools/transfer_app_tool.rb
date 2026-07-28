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
                 "Re-call with confirm: true. (credential_id + bucket are OPTIONAL — derived from the app's own R2 config if omitted.)",
        _organization: app.organization
      ))
    end

    # Object store for the DB copy. Explicit credential_id/bucket win; otherwise
    # derive them from the app's OWN R2 config (it already carries R2_ACCESS_KEY_ID /
    # R2_SECRET_ACCESS_KEY / R2_ENDPOINT), so the operator never re-enters what the
    # app already has — Conductor owns the whole cycle.
    credential, bucket, provider = resolve_object_store(app, input)
    unless credential && bucket
      return Result.fail(
        "transfer needs an object store for the DB copy — pass credential_id + bucket, " \
        "or set the app's R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT env vars."
      )
    end
    return Result.fail("Unknown object-store provider '#{provider}' — must be an S3-compatible vendor.") unless BackupVendors[provider]

    # The wired executor only handles Kamal + dedicated + colocated today (it
    # provisions via DedicatedDbProvisioner and deploys via KamalDeployer). Reject
    # any other cell up front with a clear message instead of failing mid-transfer.
    unsupported = executor_unsupported_reason(app)
    return Result.fail(unsupported) if unsupported

    # Revalidate the same way the dry-run does — a confirmed call must not skip the
    # source-server / distinct-server / org-boundary checks AppTransferPlan runs.
    AppTransferPlan.new(app: app, target_server: target).call

    transfer = AppTransfer.create!(
      app: app, organization: app.organization,
      source_server: app.server, target_server: target, mode: mode
    )
    AppTransferJob.perform_later(transfer.id, credential_id: credential.id, bucket: bucket, provider: provider)

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

  # Object store for the DB copy — Conductor owns the whole cycle, so the app's
  # existing R2 config is reused instead of demanding a re-entered credential.
  # Explicit credential_id/bucket override; otherwise derive from the app's env
  # vars (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT), find-or-updating a
  # managed "<slug> R2 (auto DB transfer)" credential so no second secret is stored.
  # Returns [credential, bucket, provider]; credential/bucket nil when neither an
  # explicit credential nor app R2 config is available.
  def resolve_object_store(app, input)
    provider = input["provider"].presence || "cloudflare_r2"

    if input["credential_id"].present?
      cred = app.organization.credentials.find_by(id: input["credential_id"])
      return [ cred, input["bucket"].presence, provider ]
    end

    ev = app.env_variables.each_with_object({}) { |v, h| h[v.key] = v.value }
    access_key = ev["R2_ACCESS_KEY_ID"]
    secret_key = ev["R2_SECRET_ACCESS_KEY"]
    account_id = ev["R2_ENDPOINT"].to_s[%r{https://([^.]+)\.}, 1]
    return [ nil, nil, provider ] if access_key.blank? || secret_key.blank? || account_id.blank?

    cred = app.organization.credentials.find_or_initialize_by(provider: "aws", name: "#{app.slug} R2 (auto DB transfer)")
    cred.update!(api_key: access_key, api_secret: secret_key, account_id: account_id)
    bucket = input["bucket"].presence || ev["R2_PRIVATE_BUCKET"].presence || "#{app.slug}-db-transfer"
    [ cred, bucket, provider ]
  end

  # The wired executor is Kamal + dedicated-container + colocated only; anything
  # else can't complete. Return a reason string, or nil when supported.
  def executor_unsupported_reason(app)
    return "transfer executes via Kamal only for now — #{app.name} deploys via #{app.deploy_method}." unless app.kamal?
    return "transfer needs a dedicated database (app is in shared-cluster mode) — convert it first." unless app.dedicated_db?
    return "transfer supports colocated dedicated DBs for now — #{app.name} is dedicated_host." unless app.colocated_db?

    nil
  end

  def find_target(input)
    if input["target_server_id"].present?
      visible_servers.find_by(id: input["target_server_id"])
    elsif input["target_server_name"].present?
      visible_servers.find_by(name: input["target_server_name"])
    end
  end

  def truthy?(value) = [ true, "true", "1", 1 ].include?(value)
end
