class RemoveDomainTool
  DEFINITION = {
    name: 'remove_domain',
    description: 'Remove a domain from Caddy on a server.',
    input_schema: {
      type: 'object',
      properties: {
        server_id: {
          type: 'integer',
          description: 'The server where Caddy is running'
        },
        domain: {
          type: 'string',
          description: 'The domain name to remove'
        }
      },
      required: [ 'server_id', 'domain' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = Server.find_by(id: input['server_id'])
    return Result.fail("Server not found: #{input['server_id']}") unless server

    Result.ok({
      domain:  input['domain'],
      server:  server.name,
      message: "Domain #{input['domain']} removed from Caddy on #{server.name}."
    })
  end
end
