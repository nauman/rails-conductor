class UpdateAppTool
  include ActorScoped

  include OrgResolvable

  DEFINITION = {
    name: 'update_app',
    description: "Update an app's configuration (deploy method, repository, branch, domain, port, notes, home server).",
    input_schema: {
      type: 'object',
      properties: {
        app_id:         { type: 'integer', description: 'App id (or use app_name)' },
        app_name:       { type: 'string',  description: 'App name (or use app_id)' },
        server_id:      { type: 'integer', description: "Set the app's home server by id (or server_name) — corrects/adopts where Conductor records the app lives (e.g. after a hand-moved deploy). Org-scoped." },
        server_name:    { type: 'string',  description: "Set the app's home server by name (or server_id)." },
        deploy_method:  { type: 'string',  description: 'One of: docker, native, kamal' },
        repository_url: { type: 'string',  description: 'Git repository URL' },
        branch:         { type: 'string',  description: 'Deploy branch' },
        domain:         { type: 'string',  description: 'Public domain' },
        port:           { type: 'integer', description: 'App port' },
        notes:          { type: 'string',  description: 'Free-form deploy notes (surfaced in fleet_status + API)' },
        deploy_hold:    { type: 'boolean', description: 'Hold deploys for this app (deploy preflight blocks). Set true when a coordination thread is owed; set false to clear.' },
        deploy_hold_reason: { type: 'string', description: 'Why the deploy is held (shown in the preflight block message).' },
        seed_on_next_deploy: { type: 'boolean', description: 'One-shot: run db:seed on the next deploy and record it to the seed ledger, then auto-clear.' }
      },
      required: []
    }
  }.freeze

  UPDATABLE = %w[deploy_method repository_url branch domain port notes deploy_hold deploy_hold_reason seed_on_next_deploy].freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    attrs = UPDATABLE.each_with_object({}) { |k, h| h[k] = input[k] if input.key?(k) }

    # Home-server change: resolve name/id to a server the actor may touch; the App
    # model's same-organization validation rejects a cross-org server on update.
    if input.key?("server_id") || input.key?("server_name")
      srv = find_server(input)
      return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless srv
      attrs["server_id"] = srv.id
    end

    return Result.fail("Nothing to update. Provide at least one field.") if attrs.empty?

    if attrs.key?("deploy_method") && !App::DEPLOY_METHODS.include?(attrs["deploy_method"])
      return Result.fail("Invalid deploy_method: #{attrs['deploy_method']} (use docker, native, or kamal)")
    end

    # Form fields route through the choke point (ADR 0004) so a box move or a
    # deploy-method switch records a revision instead of being refused.
    unless AppFormChange.update(app, attrs, user: @user, reason: "updated via MCP")
      return Result.fail(app.errors.full_messages.join(', '))
    end

    Result.ok({
      id:            app.id,
      app:           app.name,
      deploy_method: app.deploy_method,
      repository_url: app.repository_url,
      domain:        app.domain,
      notes:         app.notes,
      message:       "Updated #{app.name}.",
      _organization: app.organization || resolve_organization(input).first
    })
  end

  private

end
