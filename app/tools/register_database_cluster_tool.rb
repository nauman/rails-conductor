class RegisterDatabaseClusterTool
  include OrgResolvable

  DEFINITION = {
    name: 'register_database_cluster',
    description: 'Register a Postgres cluster (a running postgres container on a server) that apps can provision databases on.',
    input_schema: {
      type: 'object',
      properties: {
        server_id:         { type: 'integer', description: 'Server id hosting the cluster (or use server_name)' },
        server_name:       { type: 'string',  description: 'Server name hosting the cluster (or use server_id)' },
        name:              { type: 'string',  description: 'Cluster name' },
        container_name:    { type: 'string',  description: 'Docker container name of the postgres cluster (host on the shared network)' },
        admin_username:    { type: 'string',  description: 'Admin role used to provision databases' },
        admin_password:    { type: 'string',  description: 'Admin role password' },
        port:              { type: 'integer', description: 'Postgres port (default 5432)' },
        organization_slug: { type: 'string',  description: 'Optional org slug; defaults to the actor\'s first org' },
        organization_id:   { type: 'integer', description: 'Optional org id (overrides organization_slug)' }
      },
      required: [ 'name', 'container_name', 'admin_username', 'admin_password' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    org, error = resolve_organization(input)
    return Result.fail(error) if error

    server =
      if input['server_id'].present?
        org.servers.find_by(id: input['server_id'])
      elsif input['server_name'].present?
        org.servers.find_by(name: input['server_name'])
      end
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    cluster = org.database_clusters.new(
      server:         server,
      name:           input['name'],
      container_name: input['container_name'],
      admin_username: input['admin_username'],
      admin_password: input['admin_password'],
      port:           input['port'].presence || 5432
    )

    return Result.fail(cluster.errors.full_messages.join(', ')) unless cluster.save

    Result.ok({
      id:             cluster.id,
      name:           cluster.name,
      container_name: cluster.container_name,
      port:           cluster.port,
      server:         server.name,
      message:        "Database cluster #{cluster.name} registered on #{server.name}.",
      _organization:  org
    })
  end
end
