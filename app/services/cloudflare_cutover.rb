# "Put behind Cloudflare" (P2). For an app's domain: find which connected Cloudflare
# account owns the zone, flip the DNS record to proxied (orange cloud), and set the
# zone SSL mode. Default SSL "full" — safe with the current origin TLS (zero downtime),
# unlike "flexible" which requires an HTTP-only origin.
class CloudflareCutover
  include CloudflareZoneResolver

  Result = Struct.new(:ok, :message, keyword_init: true) do
    def ok? = ok
  end

  def initialize(app, client_for: nil)
    @app = app
    @client_for = client_for || ->(cred) { CloudflareClient.new(cred.api_key) }
  end

  def put_behind!(ssl_mode: "full")
    domain = @app.domain
    return failure("#{@app.name} has no domain to put behind Cloudflare.") if domain.blank?

    cred, zone = resolve_cloudflare_zone(@app.organization || @app.server&.organization, domain)
    return failure("No connected Cloudflare account owns #{domain}. Connect + Verify the account first.") unless zone

    client = @client_for.call(cred)

    rec = client.dns_record(zone["id"], domain)
    return failure("Couldn't read the DNS record for #{domain}: #{rec.error}") unless rec.ok?
    return failure("No DNS record for #{domain} in Cloudflare — add an A/CNAME first.") if rec.data.nil?

    prox = client.set_proxied(zone["id"], rec.data["id"], true)
    return failure("Enabling the proxy failed: #{prox.error}") unless prox.ok?

    ssl = client.set_ssl_mode(zone["id"], ssl_mode)
    return failure("Setting SSL mode failed: #{ssl.error}") unless ssl.ok?

    Result.new(ok: true, message: "#{domain} is now proxied through Cloudflare (#{cred.name}), SSL mode: #{ssl_mode}.")
  end

  private

  def failure(message) = Result.new(ok: false, message: message)
end
