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

    @routes = @client.fetch_routes
    @domains = [ [ @app.domain, preferred_server ] ]
    same_port_routes = @routes.select { |route| route["upstream"] == fixed_upstream }
    unrelated_same_port = same_port_routes.reject { |route| hostname_family?(route["domain"]) }
    if unrelated_same_port.any?
      raise Error, "ambiguous Caddy port ownership for #{@app.name}: #{unrelated_same_port.map { |route| route["domain"] }.uniq.join(', ')}"
    end

    @domains.concat(same_port_routes.map { |route| [ route["domain"], route["server_name"] ] })
    @domains = @domains.compact_blank.uniq
    conflicts = @routes.filter_map do |route|
      route["domain"] if hostname_family?(route["domain"]) && route["domain"] != @app.domain &&
        route["upstream"].present? && route["upstream"] != fixed_upstream
    end.uniq
    raise Error, "ambiguous Caddy hostname ownership for #{@app.name}: #{conflicts.join(', ')}" if conflicts.any?
    self
  rescue CaddyClient::Error => e
    raise Error, "cannot snapshot Caddy routes for #{@app.name}: #{e.message}"
  end

  def reconcile!
    prepare! if @domains.empty?

    upstream = fixed_upstream
    @domains.each { |domain, server_name| @client.live(domain: domain, upstream: upstream, server_name: server_name) }
    routes = @client.fetch_routes
    stale = @domains.reject do |domain, server_name|
      effective = routes.select { |route| route["domain"] == domain && route["server_name"] == server_name }.min_by { |route| route["route_index"] || 0 }
      effective && effective["upstream"] == upstream
    end
    return { domains: @domains.map(&:first), upstream: upstream, stale: [] } if stale.empty?

    raise Error, "Caddy routes remain stale for #{@app.name}: #{stale.map(&:first).join(', ')}"
  rescue CaddyClient::Error => e
    raise Error, "cannot reconcile Caddy routes for #{@app.name}: #{e.message}"
  end

  private

  def fixed_upstream = "127.0.0.1:#{@app.published_port}"

  def preferred_server
    @routes&.find { |route| route["domain"] == @app.domain }&.fetch("server_name", nil)
  end

  def hostname_family?(domain)
    host = domain.to_s.downcase
    primary = @app.domain.to_s.downcase
    host == primary || host == "www.#{primary}" || host == "*.#{primary}" || host.end_with?(".#{primary}")
  end
end
