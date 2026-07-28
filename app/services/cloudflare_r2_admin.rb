# R2 bucket administration through a connected, Verified Cloudflare account:
# CORS policy + public custom-domain delivery. Resolves which connected account
# owns the relevant zone (same pattern as CloudflareCutover), so the token and
# account_id come from Conductor's stored Credential — no vault, no secret in the
# transcript. The token must carry the "Workers R2 Storage: Edit" permission;
# without it every write returns a Cloudflare auth error (surfaced verbatim).
#
# Audit hardening: every mutating op first CLAIMS the bucket for the acting org
# (StorageBucket) so it can never touch another org's bucket on a shared account,
# and set_cors is read-modify-write so it never discards another app's rule.
class CloudflareR2Admin
  include CloudflareZoneResolver

  Result = Struct.new(:ok, :message, :data, keyword_init: true) do
    def ok? = ok
  end

  def initialize(scope, app: nil, client_for: nil)
    @scope = scope
    @app = app
    @client_for = client_for || ->(cred) { CloudflareClient.new(cred.api_key) }
  end

  # Set the bucket's CORS policy so browsers may direct-upload (PUT) and read
  # (GET) blobs. `account_domain` names any domain in the account that owns the
  # bucket (e.g. the app's apex) — it resolves the account + credential.
  # `rule_id` tags Conductor's rule so a read-modify-write can replace only it and
  # preserve every other rule on a shared bucket.
  def set_cors(bucket, account_domain:, origins:, methods: %w[GET PUT], headers: %w[*], max_age: 3600, rule_id: "conductor")
    cred, zone = resolve_cloudflare_zone(@scope, account_domain)
    return failure("No connected Cloudflare account owns #{account_domain}.") unless zone

    account_id = zone["account_id"]
    owned = claim_bucket(account_id, bucket)
    return owned if owned.is_a?(Result) # a CrossOrg failure

    client = @client_for.call(cred)

    # Read-modify-write: keep every rule we don't own, replace only ours.
    current = client.r2_cors(account_id, bucket)
    kept = current.ok? ? Array(current.data).reject { |r| rule_identifier(r) == rule_id } : []
    ours = { id: rule_id, allowed: { origins: origins, methods: methods, headers: headers },
             exposeHeaders: %w[ETag], maxAgeSeconds: max_age }

    r = client.put_r2_cors(account_id, bucket, kept + [ ours ])
    return failure("Setting CORS on #{bucket} failed: #{r.error}") unless r.ok?

    Result.new(ok: true,
               message: "CORS set on #{bucket} for #{origins.join(', ')} (#{kept.size} other rule(s) preserved).",
               data: { bucket: bucket, origins: origins, preserved_rules: kept.size })
  end

  # Connect a public custom domain to the bucket. The domain's zone must belong
  # to a connected account; Cloudflare provisions the edge cert + proxied DNS and
  # serves objects at https://<domain>/<key>. Public exposure — the caller (the
  # tool) gates this behind an explicit confirmation.
  def connect_domain(bucket, domain)
    cred, zone = resolve_cloudflare_zone(@scope, domain)
    return failure("No connected Cloudflare account owns #{domain}.") unless zone

    owned = claim_bucket(zone["account_id"], bucket)
    return owned if owned.is_a?(Result)

    client = @client_for.call(cred)
    r = client.create_r2_custom_domain(zone["account_id"], bucket, domain: domain, zone_id: zone["id"])
    return failure("Connecting #{domain} to #{bucket} failed: #{r.error}") unless r.ok?

    # Cloudflare ACCEPTING the request is not the domain being live: ownership and
    # SSL are provisioned asynchronously, and a zone hold can block activation
    # entirely. Reporting "connected" here is how "is assets.<domain> serving yet?"
    # gets answered wrong. Read the real status back instead of asserting success.
    status = custom_domain_status(client, zone["account_id"], bucket, domain)
    Result.new(ok: true,
               message: domain_message(domain, bucket, status),
               data: { bucket: bucket, domain: domain, status: status, live: status == "active" })
  end

  private

  # Bind the bucket to the acting org, or return a failure Result if it's another
  # org's. Returns nil on success (bucket now owned by @scope).
  def claim_bucket(account_id, bucket)
    StorageBucket.claim!(organization: @scope, app: @app, account_id: account_id, name: bucket)
    nil
  rescue StorageBucket::CrossOrg
    failure("Bucket #{bucket} on this Cloudflare account belongs to another organization; refusing.")
  end

  # Cloudflare's own view of the domain, right after creating it. "pending" is the
  # normal answer for the first minutes. Unknown when the read fails — say so
  # rather than guess, since the whole point is not to overstate.
  def custom_domain_status(client, account_id, bucket, domain)
    listed = client.r2_custom_domains(account_id, bucket)
    return "unknown" unless listed.ok?

    row = Array(listed.data).find { |d| (d["domain"] || d[:domain]).to_s == domain }
    (row && (row["status"] || row[:status])).presence&.to_s || "pending"
  end

  def domain_message(domain, bucket, status)
    case status
    when "active"
      "#{domain} is connected to #{bucket} and serving."
    when "unknown"
      "#{domain} was accepted for #{bucket}, but its status could not be read back — check Cloudflare before pointing traffic at it."
    else
      "#{domain} was accepted for #{bucket} and is #{status} — Cloudflare is still provisioning ownership + SSL, so it is NOT serving yet."
    end
  end

  def rule_identifier(rule) = rule["id"] || rule[:id]

  def failure(message) = Result.new(ok: false, message: message)
end
