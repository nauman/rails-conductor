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

  # Purge a zone's edge cache. Pass files: [full URLs] to purge specific assets
  # (e.g. a hashed CSS file Cloudflare cached as a 404), or omit for a full purge.
  def purge_cache(zone_id, files: nil)
    body = post("/zones/#{zone_id}/purge_cache", Array(files).any? ? { files: Array(files) } : { purge_everything: true })
    return failure(body) unless body["success"]

    Result.new(ok: true, data: body["result"])
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
