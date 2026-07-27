# Active Storage / Cloudflare R2 for a fleet app. Flat action enum:
#   audit     — where the app's blobs live (service distribution), configured
#               service, reachability, and the count NOT on the configured
#               service (read-only; runs in the app's container over SSH).
#   configure — generate the R2 storage.yml block + production.rb line + the env
#               keys to set (self-describing, ADR 0001; no secret handling).
#   migrate   — upload blobs from one service to another (e.g. local ->
#               cloudflare_r2) and repoint them; chunked + idempotent (mutating).
class ConductorStorageTool
  include ActorScoped

  DEFINITION = {
    name: "conductor_storage",
    description: "Active Storage / Cloudflare R2 for a fleet app. Set `action` to one of: " \
      "audit (where blobs live + configured service + reachability + count not on the configured service — read-only), " \
      "configure (generate the R2 storage.yml block + production.rb line + required env keys to add to the app repo — no secrets), " \
      "migrate (upload blobs from from_service to to_service, default local -> cloudflare_r2, and repoint them; chunked via limit, idempotent — mutating). " \
      "audit + migrate run `bin/rails runner` in the app's running container over SSH (Kamal/Docker apps).",
    input_schema: {
      type: "object",
      properties: {
        action:       { type: "string", enum: %w[audit configure migrate], description: "Which storage operation" },
        app_id:       { type: "integer", description: "Target app" },
        app_name:     { type: "string",  description: "Target app (alt to app_id)" },
        bucket:       { type: "string",  description: "configure: R2 bucket name" },
        account_id:   { type: "string",  description: "configure: Cloudflare account id (for the R2 endpoint)" },
        from_service: { type: "string",  description: "migrate: source service (default 'local')" },
        to_service:   { type: "string",  description: "migrate: target service (default 'cloudflare_r2')" },
        limit:        { type: "integer", description: "migrate: max migratable blobs this call (default 1000; repeat until remaining_migratable is 0)" }
      },
      required: %w[action]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found. Pass a valid app_id or app_name.") unless app

    case input["action"]
    when "audit"     then audit(app)
    when "configure" then configure(app, input)
    when "migrate"   then migrate(app, input)
    else Result.fail("Missing or unknown action. Set action to one of: audit, configure, migrate.")
    end
  end

  private

  def audit(app)
    return Result.fail(container_prereq_error(app)) unless container_capable?(app)

    r = ActiveStorageAuditor.new(app).call
    return Result.fail(r.error) unless r.ok?

    Result.ok(r.data.merge(app: app.name, _organization: app.organization))
  end

  def configure(app, input)
    bucket = input["bucket"].presence
    return Result.fail("configure requires a bucket.") unless bucket

    cfg = R2StorageConfig.new(bucket: bucket, account_id: input["account_id"]).to_h
    Result.ok(cfg.merge(app: app.name, _organization: app.organization))
  end

  def migrate(app, input)
    return Result.fail(container_prereq_error(app)) unless container_capable?(app)

    r = ActiveStorageR2Migrator.new(app).call(
      from: input["from_service"].presence || "local",
      to: input["to_service"].presence || "cloudflare_r2",
      limit: input["limit"].presence || ActiveStorageR2Migrator::DEFAULT_LIMIT
    )
    return Result.fail(r.error) unless r.ok?

    Result.ok(r.data.merge(app: app.name, _organization: app.organization))
  end

  # audit/migrate need a running container to exec into (Kamal or Docker) + SSH.
  def container_capable?(app)
    app.server&.ssh_configured? && (app.kamal? || app.docker?)
  end

  def container_prereq_error(app)
    unless app.server&.ssh_configured?
      return "#{app.name} has no server with usable SSH."
    end
    "#{app.name} deploys via #{app.deploy_method}; audit/migrate need a Kamal or Docker container to exec into."
  end
end
