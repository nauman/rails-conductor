class Edge
  # Publishes a domain on a host Caddy via its Admin API (wraps CaddyClient).
  class CaddyAdapter
    def initialize(server, client: nil)
      @server = server
      @client = client || CaddyClient.new(server)
    end

    def publish(domain:, upstream:)
      route = @client.upsert_route(domain: domain, upstream: upstream)
      { edge: "caddy", domain: domain, upstream: upstream,
        route_id: route["route_id"], action: route["action"] }
    end

    def unpublish(domain:)
      route = @client.remove_route(domain)
      { edge: "caddy", domain: domain, action: (route["action"] if route.respond_to?(:[])) || "removed" }
    end

    def maintenance(domain:, message:)
      @client.maintenance(domain: domain, message: message)
    end

    def live(domain:, upstream:, server_name: nil)
      arguments = { domain: domain, upstream: upstream }
      arguments[:server_name] = server_name if server_name.present?
      @client.live(**arguments)
    end

    def managed_domains_for_upstream(upstream)
      @client.managed_domains_for_upstream(upstream)
    end
  end
end
