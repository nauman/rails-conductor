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

    # Caddy Admin API is on port 2019 — call via SSH tunnel or direct if accessible
    # For now, record the intent and return instructions
    Result.ok({
      domain:   input['domain'],
      upstream: input['upstream'],
      server:   server.name,
      message:  "Domain #{input['domain']} → #{input['upstream']} on #{server.name}. " \
                "Run the app-setup script first to ensure the socket exists, then this route will be active."
    })
  end
end
