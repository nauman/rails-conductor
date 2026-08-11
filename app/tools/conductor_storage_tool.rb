# Active Storage / Cloudflare R2 for a fleet app. Flat action enum:
#   audit     — where the app's blobs live (service distribution), configured
#               service, reachability, and the count NOT on the configured
#               service (read-only; runs in the app's container over SSH).
#   configure — generate the R2 storage.yml block + production.rb line + the env
#               keys to set (self-describing, ADR 0001; no secret handling).
#   migrate   — upload blobs from one service to another (e.g. local ->
#               cloudflare_r2) and repoint them; chunked + idempotent (mutating).
#   set_cors  — set the R2 bucket's CORS policy so browser direct-uploads work
#               (mutating; via the connected Cloudflare account, no vault).
#   connect_domain — attach a public custom domain to the bucket for
#               Cloudflare-served, CDN-cached delivery (mutating).
class ConductorStorageTool
  include ActorScoped
  include CloudflareActorCredentials

  DEFINITION = {
    name: "conductor_storage",
    description: "Active Storage / Cloudflare R2 for a fleet app. Set `action` to one of: " \
      "audit (where blobs live + configured service + reachability + count not on the configured service — read-only), " \
      "configure (generate the R2 storage.yml block + production.rb line + required env keys to add to the app repo — no secrets), " \
      "migrate (upload blobs from from_service to to_service, default local -> cloudflare_r2, and repoint them; chunked via limit, idempotent — mutating), " \
      "set_cors (set the R2 bucket's CORS policy so browser direct_upload PUTs work — bucket + optional origins, default the app's domain + wildcard subdomains — mutating, via the connected Cloudflare account), " \
      "connect_domain (attach a public custom domain to the bucket for Cloudflare-served CDN delivery — bucket + domain; Cloudflare provisions cert + proxied DNS — mutating). " \
      "audit + migrate run `bin/rails runner` in the app's running container over SSH (Kamal/Docker apps). " \
      "create_bucket (create an R2 bucket in the connected Cloudflare account — bucket; idempotent, an existing bucket reports OK. NOT app-scoped: a fleet backup bucket belongs to no single app), " \
      "list_buckets (list the R2 buckets in the connected account — no arguments). " \
      "set_cors, connect_domain, create_bucket + list_buckets need a Verified Cloudflare account whose token carries 'Workers R2 Storage: Edit'.",
    input_schema: {
      type: "object",
      properties: {
        action:       { type: "string", enum: %w[audit configure migrate set_cors connect_domain create_bucket list_buckets], description: "Which storage operation" },
        app_id:       { type: "integer", description: "Target app" },
        app_name:     { type: "string",  description: "Target app (alt to app_id)" },
        bucket:       { type: "string",  description: "configure/set_cors/connect_domain/create_bucket: R2 bucket name" },
        location_hint: { type: "string", description: "create_bucket: physical region (wnam/enam/weur/eeur/apac/oc). PERMANENT — it cannot be changed after creation. Omit to let Cloudflare choose." },
        account_id:   { type: "string",  description: "configure: Cloudflare account id (for the R2 endpoint)" },
        from_service: { type: "string",  description: "migrate: source service (default 'local')" },
        to_service:   { type: "string",  description: "migrate: target service (default 'cloudflare_r2')" },
        limit:        { type: "integer", description: "migrate: max migratable blobs this call (default 1000; repeat until remaining_migratable is 0)" },
        origins:      { type: "array", items: { type: "string" }, description: "set_cors: allowed origins (default ['https://<app.domain>','https://*.<app.domain>'])" },
        domain:       { type: "string",  description: "connect_domain: the public custom domain to serve the bucket (e.g. assets.my-app.com)" },
        confirm:      { type: "boolean", description: "connect_domain: required to actually publish. Without it, the call returns a preview and does nothing — connect_domain makes the bucket PUBLIC on the internet." }
      },
      required: %w[action]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    # Bucket operations are ACCOUNT-scoped, not app-scoped: the fleet's backup
    # bucket belongs to no single app, and requiring one would make it
    # impossible to create exactly the bucket that was missing.
    case input["action"]
    when "create_bucket" then return create_bucket(input)
    when "list_buckets"  then return list_buckets
    end

    app = find_app(input)
    return Result.fail("App not found. Pass a valid app_id or app_name.") unless app

    case input["action"]
    when "audit"          then audit(app)
    when "configure"      then configure(app, input)
    when "migrate"        then migrate(app, input)
    when "set_cors"       then set_cors(app, input)
    when "connect_domain" then connect_domain(app, input)
    else Result.fail("Missing or unknown action. Set action to one of: audit, configure, migrate, set_cors, connect_domain, create_bucket, list_buckets.")
    end
  end

  private

  def create_bucket(input)
    bucket = input["bucket"].presence
    return Result.fail("create_bucket requires a bucket name.") unless bucket

    r = R2Bucket.new(actor_cloudflare_credentials)
                 .create!(name: bucket, location_hint: input["location_hint"].presence)
    return Result.fail(r.message) unless r.ok?

    Result.ok(bucket: r.bucket, message: r.message, _organization: Current.organization)
  end

  def list_buckets
    r = R2Bucket.new(actor_cloudflare_credentials).list
    return Result.fail(r.message) unless r.ok?

    Result.ok(buckets: r.buckets, message: r.message, _organization: Current.organization)
  end

  def set_cors(app, input)
    bucket = input["bucket"].presence
    return Result.fail("set_cors requires a bucket.") unless bucket
    return Result.fail("#{app.name} has no domain to resolve the Cloudflare account from.") if app.domain.blank?

    origins = Array(input["origins"]).map(&:to_s).reject(&:blank?)
    origins = [ "https://#{app.domain}", "https://*.#{app.domain}" ] if origins.empty?

    r = CloudflareR2Admin.new(app.organization, app: app)
      .set_cors(bucket, account_domain: app.domain, origins: origins, rule_id: "conductor-#{app.slug}")
    return Result.fail(r.message) unless r.ok?

    Result.ok(r.data.merge(app: app.name, message: r.message, _organization: app.organization))
  end

  def connect_domain(app, input)
    bucket = input["bucket"].presence
    domain = input["domain"].presence
    return Result.fail("connect_domain requires a bucket.") unless bucket
    return Result.fail("connect_domain requires a domain (e.g. assets.#{app.domain}).") unless domain

    # Public-exposure gate: connect_domain makes the bucket readable to the whole
    # internet, so it never fires on a bare call — it previews and requires confirm.
    unless truthy?(input["confirm"])
      return Result.ok(
        status: "confirmation_required", action_taken: false,
        bucket: bucket, domain: domain,
        will: "make bucket '#{bucket}' PUBLIC, served at https://#{domain}/<key> (Cloudflare provisions a cert + proxied DNS)",
        message: "connect_domain publishes the bucket to the internet. Re-call with confirm: true to proceed.",
        _organization: app.organization
      )
    end

    r = CloudflareR2Admin.new(app.organization, app: app).connect_domain(bucket, domain)
    return Result.fail(r.message) unless r.ok?

    Result.ok(r.data.merge(app: app.name, message: r.message, _organization: app.organization))
  end

  def truthy?(value) = [ true, "true", "1", 1 ].include?(value)

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
