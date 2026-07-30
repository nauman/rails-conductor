class RemoveStrayProxyTool
  include ActorScoped

  DEFINITION = {
    name: "remove_stray_proxy",
    description: "Remove an INERT kamal-proxy container left on a host-Caddy box after it migrated off kamal-proxy. Report-first: a bare call SSH-inspects and reports; confirm:true removes. Refuses unless the box is host-Caddy AND kamal-proxy routes nothing / binds nothing — so it can never break a live proxy box. Touches only the kamal-proxy container.",
    input_schema: {
      type: "object",
      properties: {
        server_id:   { type: "integer", description: "The host-Caddy server (or server_name)" },
        server_name: { type: "string",  description: "The host-Caddy server by name (or server_id)" },
        confirm:     { type: "boolean", description: "Required to remove. Without it, returns the inspection report and does NOTHING." }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = resolve_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    cleaner = StrayProxyCleaner.new(server)
    res = input["confirm"] ? cleaner.remove! : cleaner.inspect_only

    # A confirmed run that couldn't proceed (unsafe) or failed is a failure, so the
    # caller sees why rather than a false success.
    if input["confirm"] && !res.removed
      return Result.fail(res.message)
    end

    Result.ok({
      server: server.name,
      findings: res.findings,
      safe: res.safe,
      removed: res.removed,
      action_taken: res.removed,
      message: res.message,
      _organization: server.organization
    })
  rescue StandardError => e
    Result.fail("stray-proxy cleanup failed on the box: #{e.message}")
  end

  private

  def resolve_server(input)
    if input["server_id"].present?
      visible_servers.find_by(id: input["server_id"])
    elsif input["server_name"].present?
      visible_servers.find_by(name: input["server_name"])
    end
  end
end
