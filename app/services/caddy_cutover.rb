# Mandatory postcondition for Kamal-deployed apps whose edge is host Caddy.
#
# Caddy routes are the source of truth for alternate hostnames. They may be
# legacy/no-id routes, so this service deliberately uses the complete route
# inventory rather than only Conductor-managed routes.
class CaddyCutover
  class Error < StandardError; end

  def initialize(app, client: nil)
    @app = app
    @client = client || CaddyClient.new(app.server)
    @domains = []
  end

  # Capture hostnames before the fixed-port container is stopped. The primary
  # domain is always included; routes already targeting the app port add its
  # wildcard/www/alias family, including routes without @id.
  def prepare!
    raise Error, "#{@app.name} has no primary domain" if @app.domain.blank?

    @domains = [ @app.domain ]
    @domains.concat(@client.fetch_routes.filter_map do |route|
      route["domain"] if route["upstream"] == fixed_upstream || hostname_family?(route["domain"])
    end)
    @domains = @domains.compact_blank.uniq
    self
  rescue CaddyClient::Error => e
    raise Error, "cannot snapshot Caddy routes for #{@app.name}: #{e.message}"
  end

  def reconcile!
    prepare! if @domains.empty?

    upstream = fixed_upstream
    @domains.each { |domain| @client.live(domain: domain, upstream: upstream) }
    routes = @client.fetch_routes
    stale = @domains.reject do |domain|
      routes.any? { |route| route["domain"] == domain && route["upstream"] == upstream }
    end
    return { domains: @domains, upstream: upstream, stale: [] } if stale.empty?

    raise Error, "Caddy routes remain stale for #{@app.name}: #{stale.join(', ')}"
  rescue CaddyClient::Error => e
    raise Error, "cannot reconcile Caddy routes for #{@app.name}: #{e.message}"
  end

  private

  def fixed_upstream = "127.0.0.1:#{@app.published_port}"

  def hostname_family?(domain)
    host = domain.to_s.downcase
    primary = @app.domain.to_s.downcase
    host == primary || host == "www.#{primary}" || host == "*.#{primary}" || host.end_with?(".#{primary}")
  end
end
