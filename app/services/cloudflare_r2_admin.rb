# R2 bucket administration through a connected, Verified Cloudflare account:
# CORS policy + public custom-domain delivery. Resolves which connected account
# owns the relevant zone (same pattern as CloudflareCutover), so the token and
# account_id come from Conductor's stored Credential — no vault, no secret in the
# transcript. The token must carry the "Workers R2 Storage: Edit" permission;
# without it every write returns a Cloudflare auth error (surfaced verbatim).
class CloudflareR2Admin
  include CloudflareZoneResolver

  Result = Struct.new(:ok, :message, :data, keyword_init: true) do
    def ok? = ok
  end

  def initialize(scope, client_for: nil)
    @scope = scope
    @client_for = client_for || ->(cred) { CloudflareClient.new(cred.api_key) }
  end

  # Set the bucket's CORS policy so browsers may direct-upload (PUT) and read
  # (GET) blobs. `account_domain` names any domain in the account that owns the
  # bucket (e.g. the app's apex) — it resolves the account + credential.
  def set_cors(bucket, account_domain:, origins:, methods: %w[GET PUT], headers: %w[*], max_age: 3600)
    cred, zone = resolve_cloudflare_zone(@scope, account_domain)
    return failure("No connected Cloudflare account owns #{account_domain}.") unless zone

    rules = [ { allowed: { origins: origins, methods: methods, headers: headers }, exposeHeaders: %w[ETag], maxAgeSeconds: max_age } ]
    r = @client_for.call(cred).put_r2_cors(zone["account_id"], bucket, rules)
    return failure("Setting CORS on #{bucket} failed: #{r.error}") unless r.ok?

    Result.new(ok: true, message: "CORS set on #{bucket} for #{origins.join(', ')}.", data: { bucket: bucket, origins: origins })
  end

  # Connect a public custom domain to the bucket. The domain's zone must belong
  # to a connected account; Cloudflare provisions the edge cert + proxied DNS and
  # serves objects at https://<domain>/<key>.
  def connect_domain(bucket, domain)
    cred, zone = resolve_cloudflare_zone(@scope, domain)
    return failure("No connected Cloudflare account owns #{domain}.") unless zone

    r = @client_for.call(cred).create_r2_custom_domain(zone["account_id"], bucket, domain: domain, zone_id: zone["id"])
    return failure("Connecting #{domain} to #{bucket} failed: #{r.error}") unless r.ok?

    Result.new(ok: true, message: "#{domain} connected to #{bucket} — Cloudflare is provisioning the cert.", data: { bucket: bucket, domain: domain })
  end

  private

  def failure(message) = Result.new(ok: false, message: message)
end
