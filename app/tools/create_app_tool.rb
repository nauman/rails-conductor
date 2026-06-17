class CreateAppTool
  include OrgResolvable

  DEFINITION = {
    name: 'create_app',
    description: 'Create an app to deploy onto a server (docker or native), optionally with a domain, port, branch and deploy notes.',
    input_schema: {
      type: 'object',
      properties: {
        name:              { type: 'string',  description: 'App name' },
        repository_url:    { type: 'string',  description: 'Git repository URL to deploy from' },
        server_id:         { type: 'integer', description: 'Server id to deploy to (or use server_name)' },
        server_name:       { type: 'string',  description: 'Server name to deploy to (or use server_id)' },
        deploy_method:     { type: 'string',  description: 'Deploy method: docker or native', enum: %w[docker native] },
        domain:            { type: 'string',  description: 'Optional public domain' },
        port:              { type: 'integer', description: 'Optional app port' },
        branch:            { type: 'string',  description: 'Optional git branch (default main)' },
        notes:             { type: 'string',  description: 'Optional free-form deploy notes' },
        organization_slug: { type: 'string',  description: 'Optional org slug; defaults to the actor\'s first org' },
        organization_id:   { type: 'integer', description: 'Optional org id (overrides organization_slug)' }
      },
      required: [ 'name', 'repository_url', 'deploy_method' ]
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
    if (input['server_id'].present? || input['server_name'].present?) && server.nil?
      return Result.fail("Server not found: #{input['server_id'] || input['server_name']}")
    end

    app = org.apps.new(
      name:           input['name'],
      repository_url: input['repository_url'],
      deploy_method:  input['deploy_method'],
      server:         server,
      domain:         input['domain'].presence,
      port:           input['port'].presence,
      branch:         input['branch'].presence || 'main',
      notes:          input['notes'].presence
    )

    return Result.fail(app.errors.full_messages.join(', ')) unless app.save

    Result.ok({
      id:             app.id,
      name:           app.name,
      slug:           app.slug,
      deploy_method:  app.deploy_method,
      domain:         app.domain,
      port:           app.port,
      branch:         app.branch,
      notes:          app.notes,
      server:         server&.name,
      message:        "App #{app.name} created in #{org.name}.",
      _organization:  org
    })
  end
end
