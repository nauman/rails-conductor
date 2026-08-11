class EnableOnDemandTlsTool
  include ActorScoped

  DEFINITION = {
    name: "enable_on_demand_tls",
    description: "Enable Caddy on-demand TLS for a zone on a host-Caddy server, so each subdomain gets its own Let's Encrypt cert issued on first request and gated by an app's ask endpoint. Use when Cloudflare can't proxy the wildcard (free plan) and a DNS-challenge wildcard cert isn't wanted. Reusable by any host-Caddy app.",
    input_schema: {
      type: "object",
      properties: {
        server_id:    { type: "integer", description: "The host-Caddy server (or server_name)" },
        server_name:  { type: "string",  description: "The host-Caddy server by name (or server_id)" },
        domain:       { type: "string",  description: "The zone whose subdomains go on-demand, e.g. my-app.com (the on-demand subject becomes *.my-app.com)" },
        ask_upstream: { type: "string",  description: "host:port that serves the ask endpoint — the app's loopback publish, e.g. 127.0.0.1:9080" },
        ask_path:     { type: "string",  description: "Path of the ask endpoint (default /caddy/ask)" },
        subject:      { type: "string",  description: "Override the on-demand subject directly (default *.<domain>)" }
      },
      required: %w[domain ask_upstream]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = resolve_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    domain = input["domain"].to_s.strip.downcase
    return Result.fail("domain is required") if domain.blank?

    ask_upstream = input["ask_upstream"].to_s.strip
    return Result.fail("ask_upstream is required (host:port serving the ask endpoint)") if ask_upstream.blank?

    subject = input["subject"].presence&.strip&.downcase || "*.#{domain}"
    path    = input["ask_path"].presence || "/caddy/ask"
    path    = "/#{path}" unless path.start_with?("/")
    ask_url = "http://#{ask_upstream}#{path}"

    result = CaddyClient.new(server).enable_on_demand_tls(subject: subject, ask_url: ask_url)

    Result.ok(result.merge(
      "server" => server.name,
      "message" => "On-demand TLS enabled for #{subject} on #{server.name} (ask → #{ask_url}). Subdomains now get a per-name Let's Encrypt cert on first request, gated by the ask endpoint.",
      "_organization" => server.organization
    ))
  rescue CaddyClient::Error => e
    Result.fail(e.message)
  end

  private

  # Accept either id or name, scoped to servers the actor may touch.
  def resolve_server(input)
    if input["server_id"].present?
      visible_servers.find_by(id: input["server_id"])
    elsif input["server_name"].present?
      visible_servers.find_by(name: input["server_name"])
    end
  end
end
