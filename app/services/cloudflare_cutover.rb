# "Put behind Cloudflare" (P2). For an app's domain: find which connected Cloudflare
# account owns the zone, flip the DNS record to proxied (orange cloud), and set the
# zone SSL mode. Default SSL "full" — safe with the current origin TLS (zero downtime),
# unlike "flexible" which requires an HTTP-only origin.
class CloudflareCutover
  include CloudflareZoneResolver

  Result = Struct.new(:ok, :message, keyword_init: true) do
    def ok? = ok
  end

  # Said at the moment the requirement is CREATED, because this is silent
  # otherwise and stays wrong for months.
  #
  # Once a domain is proxied, every request reaches the origin from a Cloudflare
  # edge. Rails computes request.remote_ip from X-Forwarded-For but only skips
  # proxies it trusts, and it trusts private ranges by default — Cloudflare's are
  # public. So remote_ip becomes the EDGE, and every per-IP behaviour in the app
  # silently starts treating thousands of visitors as a handful of addresses:
  # rate limiting, abuse controls, geo, analytics, per-IP connection accounting.
  #
  # Observed on this fleet: one Cloudflare address accounted for 91 requests in a
  # three-minute window, and no client's real address appeared even once.
  #
  # Nothing breaks loudly. That is the problem.
  REAL_IP_WARNING = <<~TXT.squish.freeze
    NOTE: the app must now trust Cloudflare's ranges or request.remote_ip will be a
    Cloudflare edge for every visitor — set config.action_dispatch.trusted_proxies
    to include https://www.cloudflare.com/ips-v4 and /ips-v6 (plus the private
    ranges Rails trusts by default). Until then any per-IP logic (rate limiting,
    abuse controls, analytics) sees a handful of addresses instead of your users.
  TXT

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

    Result.new(ok: true, message: "#{domain} is now proxied through Cloudflare (#{cred.name}), " \
                                  "SSL mode: #{ssl_mode}. #{REAL_IP_WARNING}")
  end

  private

  def failure(message) = Result.new(ok: false, message: message)
end
