class Edge
  # Publishes a domain on a kamal-proxy box.
  #
  # Unlike Caddy (imperative Admin API), kamal-proxy routing is DECLARATIVE: a
  # host is registered when the app deploys with `proxy: { host: <domain> }` in
  # its deploy.yml — which Conductor generates (KamalConfig#proxy_block). So on a
  # kamal-proxy target the domain is published by the transfer's compute-phase
  # deploy, and the edge phase is a confirming no-op rather than a separate
  # mutation. This matches Decision D (ship cold cut-over first): the route flips
  # with the deploy. A future live/instant cut-over could shell kamal-proxy over
  # SSH, but that's an enhancement, not required for correctness.
  class KamalProxyAdapter
    def initialize(server, **_opts)
      @server = server
    end

    def publish(domain:, upstream:)
      {
        edge: "kamal_proxy", domain: domain, upstream: upstream, applied_by: "deploy",
        note: "kamal-proxy registers host→app from the app's deploy.yml proxy.host on deploy; " \
              "the compute-phase deploy to this box publishes the route (no separate edge call)."
      }
    end

    def unpublish(domain:)
      {
        edge: "kamal_proxy", domain: domain, applied_by: "deploy",
        note: "route is withdrawn when the app is undeployed or redeployed without this host."
      }
    end
  end
end
