class RegisterServerTool
  include OrgResolvable

  DEFINITION = {
    name: 'register_server',
    description: 'Register a new server (host) in the fleet so apps can be deployed to it.',
    input_schema: {
      type: 'object',
      properties: {
        name:              { type: 'string',  description: 'Unique server name' },
        ip_address:        { type: 'string',  description: 'Public IP address or hostname' },
        ssh_user:          { type: 'string',  description: 'SSH login user (e.g. deploy, root)' },
        ssh_key_id:        { type: 'integer', description: 'Optional SshKey id for SSH auth' },
        provider:          { type: 'string',  description: 'Optional provider: hetzner, digitalocean, linode, vultr, aws, gcp, azure' },
        organization_slug: { type: 'string',  description: 'Optional org slug (parameterized name); defaults to the actor\'s first org' },
        organization_id:   { type: 'integer', description: 'Optional org id (overrides organization_slug)' }
      },
      required: [ 'name', 'ip_address', 'ssh_user' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    org, error = resolve_organization(input)
    return Result.fail(error) if error

    server = org.servers.new(
      name:       input['name'],
      ip_address: input['ip_address'],
      ssh_user:   input['ssh_user'],
      ssh_key_id: input['ssh_key_id'],
      provider:   input['provider'].presence,
      status:     'offline'
    )

    return Result.fail(server.errors.full_messages.join(', ')) unless server.save

    Result.ok({
      id:            server.id,
      name:          server.name,
      ip_address:    server.ip_address,
      ssh_user:      server.ssh_user,
      provider:      server.provider,
      status:        server.status,
      message:       "Server #{server.name} registered in #{org.name}.",
      _organization: org
    })
  end
end
