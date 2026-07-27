require "net/http"
require "json"

# Minimal Cloudflare API client for a single connected account (token = bearer).
# P1 scope: verify the token and list the account's zones so Conductor can resolve
# domain → zone → account. Later phases add DNS-record + zone-settings writes.
class CloudflareClient
  API = "https://api.cloudflare.com/client/v4".freeze
  Result = Struct.new(:ok, :data, :error, keyword_init: true) do
    def ok? = ok
  end

  def initialize(token, http: nil)
    @token = token
    @http = http # injectable for tests: responds to get(path) → parsed Hash
  end

  # GET /user/tokens/verify — is the token live?
  def verify
    body = get("/user/tokens/verify")
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # GET /zones — [{id, name, account_id}], first 50 (enough for our fleets).
  def zones
    body = get("/zones?per_page=50")
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"].map { |z| { "id" => z["id"], "name" => z["name"], "account_id" => z.dig("account", "id") } })
  end

  # --- P2: put behind Cloudflare (proxy the DNS record + set SSL mode) ---

  # The A/CNAME record for a hostname in a zone (proxied status lives on it).
  def dns_record(zone_id, name)
    body = get("/zones/#{zone_id}/dns_records?name=#{name}")
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"].first) # nil if the host has no record
  end

  # Flip a record's orange cloud on/off (partial PATCH — proxied only).
  def set_proxied(zone_id, record_id, proxied)
    body = patch("/zones/#{zone_id}/dns_records/#{record_id}", { proxied: proxied })
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # Zone SSL mode: "off" | "flexible" | "full" | "strict".
  def set_ssl_mode(zone_id, mode)
    body = patch("/zones/#{zone_id}/settings/ssl", { value: mode })
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # Create or update an A/CNAME record by name. Idempotent: PATCHes the existing
  # record for that name if one exists, else POSTs a new one. ttl 1 = "automatic".
  def upsert_dns_record(zone_id, name:, content:, type: "A", proxied: false, ttl: 1)
    existing = dns_record(zone_id, name)
    return existing unless existing.ok? # propagate the read error

    body = { type: type, name: name, content: content, proxied: proxied, ttl: ttl }
    resp = if existing.data
      patch("/zones/#{zone_id}/dns_records/#{existing.data['id']}", body)
    else
      post("/zones/#{zone_id}/dns_records", body)
    end
    return failure(resp) unless resp["success"]

    Result.new(ok: true, data: resp["result"])
  end

  # Delete a DNS record by id (resolve the id first via #dns_record).
  def delete_dns_record(zone_id, record_id)
    resp = delete("/zones/#{zone_id}/dns_records/#{record_id}")
    return failure(resp) unless resp["success"]

    Result.new(ok: true, data: resp["result"])
  end

  # Purge a zone's edge cache. Pass files: [full URLs] to purge specific assets
  # (e.g. a hashed CSS file Cloudflare cached as a 404), or omit for a full purge.
  def purge_cache(zone_id, files: nil)
    body = post("/zones/#{zone_id}/purge_cache", Array(files).any? ? { files: Array(files) } : { purge_everything: true })
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # --- R2 object storage (account-scoped API: /accounts/{acct}/r2/...) ---
  # These need the token to carry the "Workers R2 Storage: Edit" permission;
  # read-only tokens can list/get but every write returns an auth error.

  # [{name, location, creation_date}, ...] for the account.
  def r2_buckets(account_id)
    body = get("/accounts/#{account_id}/r2/buckets")
    return failure(body) unless body["success"]

    Result.new(ok: true, data: Array(body.dig("result", "buckets")))
  end

  # One bucket's metadata ({name, location, storage_class, jurisdiction}).
  def r2_bucket(account_id, name)
    body = get("/accounts/#{account_id}/r2/buckets/#{name}")
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # Create a bucket. location_hint is one of wnam/enam/weur/eeur/apac/oc — it fixes
  # the bucket's physical region and CANNOT be changed after creation.
  def create_r2_bucket(account_id, name, location_hint: nil)
    payload = { name: name }
    payload[:locationHint] = location_hint if location_hint.present?
    body = post("/accounts/#{account_id}/r2/buckets", payload)
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # Delete a bucket (must be empty).
  def delete_r2_bucket(account_id, name)
    body = delete("/accounts/#{account_id}/r2/buckets/#{name}")
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # Read the bucket's CORS rules (nil-safe: [] when none configured).
  def r2_cors(account_id, bucket)
    body = get("/accounts/#{account_id}/r2/buckets/#{bucket}/cors")
    return failure(body) unless body["success"]

    Result.new(ok: true, data: Array(body.dig("result", "rules")))
  end

  # Replace the bucket's CORS policy. `rules` is an array of R2 CORS rule hashes,
  # e.g. [{ allowed: { origins:, methods:, headers: }, exposeHeaders:, maxAgeSeconds: }].
  def put_r2_cors(account_id, bucket, rules)
    body = put("/accounts/#{account_id}/r2/buckets/#{bucket}/cors", { rules: rules })
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # Connect a custom domain to the bucket for public, Cloudflare-served delivery.
  # The domain's zone must be in the same account; Cloudflare provisions the cert
  # and (when enabled) the proxied DNS record.
  def create_r2_custom_domain(account_id, bucket, domain:, zone_id:, enabled: true)
    payload = { domain: domain, zoneId: zone_id, enabled: enabled }
    body = post("/accounts/#{account_id}/r2/buckets/#{bucket}/domains/custom", payload)
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
  end

  # [{domain, enabled, status, ...}, ...] custom domains bound to the bucket.
  def r2_custom_domains(account_id, bucket)
    body = get("/accounts/#{account_id}/r2/buckets/#{bucket}/domains/custom")
    return failure(body) unless body["success"]

    Result.new(ok: true, data: Array(body.dig("result", "domains")))
  end

  private

  def failure(body)
    msg = Array(body["errors"]).map { |e| e["message"] }.join("; ").presence || "Cloudflare API error"
    Result.new(ok: false, error: msg)
  end

  def get(path)
    return @http.get(path) if @http # test seam

    request(Net::HTTP::Get.new(URI("#{API}#{path}")))
  end

  def patch(path, body)
    return @http.patch(path, body) if @http # test seam

    req = Net::HTTP::Patch.new(URI("#{API}#{path}"))
    req.body = body.to_json
    request(req)
  end

  def post(path, body)
    return @http.post(path, body) if @http # test seam

    req = Net::HTTP::Post.new(URI("#{API}#{path}"))
    req.body = body.to_json
    request(req)
  end

  def put(path, body)
    return @http.put(path, body) if @http # test seam

    req = Net::HTTP::Put.new(URI("#{API}#{path}"))
    req.body = body.to_json
    request(req)
  end

  def delete(path)
    return @http.delete(path) if @http # test seam

    request(Net::HTTP::Delete.new(URI("#{API}#{path}")))
  end

  def request(req)
    uri = req.uri
    req["Authorization"] = "Bearer #{@token}"
    req["Content-Type"] = "application/json"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 12) { |h| h.request(req) }
    JSON.parse(res.body)
  rescue => e
    { "success" => false, "errors" => [ { "message" => e.message } ] }
  end
end
