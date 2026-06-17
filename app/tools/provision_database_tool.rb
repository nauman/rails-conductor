class ProvisionDatabaseTool
  include OrgResolvable

  DEFINITION = {
    name: 'provision_database',
    description: 'Provision a Postgres database (role + database + password) on a registered cluster and return its connection URL.',
    input_schema: {
      type: 'object',
      properties: {
        cluster_id:        { type: 'integer', description: 'Cluster id to provision on (or use cluster_name)' },
        cluster_name:      { type: 'string',  description: 'Cluster name to provision on (or use cluster_id)' },
        name:              { type: 'string',  description: 'Database name' },
        username:          { type: 'string',  description: 'Optional role name (defaults to the database name)' },
        app_id:            { type: 'integer', description: 'Optional app id to link the database to' },
        organization_slug: { type: 'string',  description: 'Optional org slug; defaults to the actor\'s first org' },
        organization_id:   { type: 'integer', description: 'Optional org id (overrides organization_slug)' }
      },
      required: [ 'name' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    org, error = resolve_organization(input)
    return Result.fail(error) if error

    cluster =
      if input['cluster_id'].present?
        org.database_clusters.find_by(id: input['cluster_id'])
      elsif input['cluster_name'].present?
        org.database_clusters.find_by(name: input['cluster_name'])
      end
    return Result.fail("Cluster not found: #{input['cluster_id'] || input['cluster_name']}") unless cluster

    app = org.apps.find_by(id: input['app_id']) if input['app_id'].present?
    return Result.fail("App not found: #{input['app_id']}") if input['app_id'].present? && app.nil?

    database = cluster.provision_database!(
      name: input['name'], username: input['username'].presence, app: app
    )

    Result.ok({
      id:            database.id,
      name:          database.name,
      username:      database.username,
      status:        database.status,
      database_url:  database.database_url,
      app_id:        database.app_id,
      message:       "Database #{database.name} provisioned on #{cluster.name}.",
      _organization: org
    })
  rescue PostgresClusterClient::Error, ActiveRecord::RecordInvalid => e
    Result.fail("Could not provision database: #{e.message}")
  end
end
