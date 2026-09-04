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
        name:              { type: 'string',  description: 'Database name. OMIT IT and pass app_id to follow the convention: <app>_production with a matching role. Pass it only to CREATE a database under a different name — this always runs CREATE ROLE + CREATE DATABASE and fails if either already exists; it does not adopt.' },
        username:          { type: 'string',  description: 'Optional role name. With app_id and no name, defaults to the app convention; with an explicit name, defaults to that name (the role follows the database being created, not the app).' },
        app_id:            { type: 'integer', description: 'Optional app id to link the database to' },
        organization_slug: { type: 'string',  description: 'Optional org slug; defaults to the actor\'s first org' },
        organization_id:   { type: 'integer', description: 'Optional org id (overrides organization_slug)' }
      },
      required: []
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

    # THE CONVENTION HAS TO LIVE HERE, not only in the schema text. This tool is the
    # path an agent takes to give a brand-new app its database, so passing `name`
    # straight through meant the caller most likely to have no name to pass was the
    # one with no default — and a nil name reached CREATE DATABASE as a validation
    # error rather than a database.
    name     = input['name'].presence || app&.database_name
    username = input['username'].presence || (input['name'].blank? ? app&.database_username : nil)

    unless name
      return Result.fail(
        'Provide app_id to follow the naming convention (<app>_production with a ' \
        'matching role), or name to create one under a different name.'
      )
    end

    database = cluster.provision_database!(name: name, username: username, app: app)

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
