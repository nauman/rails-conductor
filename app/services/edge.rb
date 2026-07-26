# Uniform edge publishing across heterogeneous servers (app-transfer spec 26,
# Part 2). `Edge.for(server).publish(domain:, upstream:)` renders/applies the
# route on whatever fronts that server's :80/:443, dispatched by
# Server#edge_type — so a cross-edge transfer stops being special-cased.
class Edge
  class UnsupportedEdge < StandardError; end

  # Returns the adapter for the server's detected edge. Extra kwargs pass
  # through to the adapter (e.g. an injected client for tests).
  def self.for(server, **opts)
    case server.edge_type
    when "caddy"       then CaddyAdapter.new(server, **opts)
    when "kamal_proxy" then KamalProxyAdapter.new(server, **opts)
    else
      raise UnsupportedEdge,
        "no edge adapter for #{server.name} (edge_type=#{server.edge_type.inspect}); run edge detection first"
    end
  end
end
