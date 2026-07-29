# Convert an app's database IN PLACE from shared-cluster → dedicated container,
# so it becomes the portable unit a transfer requires. This is the ignition for
# SharedToDedicatedConverter — the transfer refuses shared-DB apps ("convert it
# first"), and this is that first step.
#
# CONFIRM-GATED and outward-facing: it provisions a dedicated DB container, copies
# the app's data into it, and drops the manual DATABASE_URL so the derived
# dedicated DSN takes over at the next deploy. It is REVERSIBLE until the operator
# redeploys — the shared database is left intact and the old DSN is preserved as
# DATABASE_URL_PRE_CONVERT — but a bare call previews and mutates nothing.
#
# The DB copy stages through object storage exactly like the transfer, and reuses
# the app's OWN R2 config (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT)
# when credential_id/bucket are omitted, so no second secret is ever re-entered —
# Conductor owns the whole cycle.
class ConvertDatabaseAppTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    # Preview unless explicitly confirmed — never mutate on a bare call.
    unless truthy?(input["confirm"])
      return Result.ok(
        status: "confirmation_required", action_taken: false,
        app: app.name, from: "shared", to: "dedicated (colocated)",
        message: "This will convert #{app.name} to a dedicated colocated DB: provision a " \
                 "<#{app.slug}>-db container, copy the data, and switch DATABASE_URL to the " \
                 "derived dedicated DSN (old value kept as DATABASE_URL_PRE_CONVERT). The shared " \
                 "DB is left intact — reversible until you redeploy. Re-call with confirm: true. " \
                 "(credential_id + bucket are OPTIONAL — derived from the app's own R2 config.)",
        _organization: app.organization
      )
    end

    # Object store for the DB copy — reuse the app's own R2 config when not given.
    credential, bucket, provider = resolve_object_store(app, input)
    unless credential && bucket
      return Result.fail(
        "convert needs an object store for the DB copy — pass credential_id + bucket, " \
        "or set the app's R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT env vars."
      )
    end
    return Result.fail("Unknown object-store provider '#{provider}' — must be an S3-compatible vendor.") unless BackupVendors[provider]

    result = SharedToDedicatedConverter.new(app).call(credential: credential, bucket: bucket, provider: provider)
    return Result.fail(result.message) unless result.ok?

    Result.ok(
      status: "converted", action_taken: true, app: app.name,
      message: result.message, next: result.data&.dig(:next),
      rollback_dsn_key: result.data&.dig(:rollback_dsn_key),
      _organization: app.organization
    )
  end

  private

  # Same object-store resolution as the transfer: explicit credential_id/bucket
  # win; otherwise derive a managed "<slug> R2 (auto DB transfer)" credential from
  # the app's own R2 env so no second secret is stored. Returns [credential,
  # bucket, provider]; credential/bucket nil when neither is available.
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

  def truthy?(value) = [ true, "true", "1", 1 ].include?(value)
end
