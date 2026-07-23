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

  private

  def failure(body)
    msg = Array(body["errors"]).map { |e| e["message"] }.join("; ").presence || "Cloudflare API error"
    Result.new(ok: false, error: msg)
  end

  def get(path)
    return @http.get(path) if @http # test seam

    uri = URI("#{API}#{path}")
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{@token}"
    req["Content-Type"] = "application/json"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 12) { |h| h.request(req) }
    JSON.parse(res.body)
  rescue => e
    { "success" => false, "errors" => [ { "message" => e.message } ] }
  end
end
