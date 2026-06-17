class AddDomainTool
  DEFINITION = {
    name: 'add_domain',
    description: 'Add a domain to Caddy on a server, routing it to an app via its socket or port.',
    input_schema: {
      type: 'object',
      properties: {
        server_id: {
          type: 'integer',
          description: 'The server where Caddy is running'
        },
        domain: {
          type: 'string',
          description: 'The domain name to route (e.g. myapp.com)'
        },
        upstream: {
          type: 'string',
          description: 'Where to route traffic: unix socket path (e.g. /tmp/puma-myapp.sock) or host:port (e.g. localhost:3000)'
        }
      },
      required: [ 'server_id', 'domain', 'upstream' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = Server.find_by(id: input['server_id'])
    return Result.fail("Server not found: #{input['server_id']}") unless server

    route = CaddyClient.new(server).upsert_route(
      domain: input['domain'],
      upstream: input['upstream']
    )

    Result.ok({
      domain: input['domain'],
      upstream: input['upstream'],
      server: server.name,
      route_id: route['route_id'],
      action: route['action'],
      message: "Domain #{input['domain']} now routes to #{input['upstream']} on #{server.name}.",
      # _organization: org this call touched; logged by the MCP controller, then stripped.
      _organization: server.organization
    })
  rescue CaddyClient::Error => e
    Result.fail(e.message)
  end
end
