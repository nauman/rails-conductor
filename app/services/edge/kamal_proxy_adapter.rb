class Edge
  # Publishes a domain on a kamal-proxy box. The dispatch seam exists so
  # `Edge.for(server)` is uniform, but the live-apply mechanism (kamal-proxy CLI
  # over SSH vs rendering the deploy.yml `proxy:` block) is owned by
  # conductor-deployer — it's their kamal/deploy surface. Tracked in the Agents
  # node thread. Until it lands, transfers target Caddy edges; a kamal-proxy
  # target raises loudly rather than silently no-op'ing.
  class KamalProxyAdapter
    class Pending < StandardError; end

    def initialize(server, **_opts)
      @server = server
    end

    def publish(domain:, upstream:)
      raise Pending,
        "KamalProxyAdapter#publish(#{domain} -> #{upstream}) is not implemented yet — " \
        "coordinate the kamal-proxy edge mechanism with conductor-deployer"
    end

    def unpublish(domain:)
      raise Pending, "KamalProxyAdapter#unpublish(#{domain}) is not implemented yet"
    end
  end
end
