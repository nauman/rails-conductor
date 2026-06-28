class DeployAppTool
  include ActorScoped

  DEFINITION = {
    name: 'deploy_app',
    description: "Deploy an app to its latest commit. Creates a Deployment and dispatches by the app's deploy_method (native, docker, or kamal).",
    input_schema: {
      type: 'object',
      properties: {
        app_id: {
          type: 'integer',
          description: 'The ID of the app to deploy'
        },
        app_name: {
          type: 'string',
          description: 'The name of the app to deploy (alternative to app_id)'
        }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found. Provide app_id or app_name.") unless app
    return Result.fail("App '#{app.name}' is not deployable (needs a server with SSH + a repository).") unless app.deployable?

    # Single-flight: a duplicate trigger (rapid double-fire from chat, or MCP + the
    # UI button) returns the in-flight deployment as already_running rather than
    # starting a second kamal deploy. The DB invariant guarantees exactly one.
    deployment, already_running = app.start_deployment!(user: @user)

    if already_running
      return Result.ok({
        deployment_id: deployment&.id,
        app:           app.name,
        status:        'already_running',
        message:       "A deployment is already in progress for #{app.name}. Deployment ID: #{deployment&.id}.",
        _organization: app.organization || app.server.organization
      })
    end

    Result.ok({
      deployment_id: deployment.id,
      app:           app.name,
      server:        app.server.name,
      deploy_method: app.deploy_method,
      status:        'started',
      message:       "Deploying #{app.name} (#{app.deploy_method}) on #{app.server.name}. Deployment ID: #{deployment.id}",
      # _organization: the org this call touched. The MCP controller reads this to
      # log the affected org on the McpCall, then strips it before responding.
      _organization: app.organization || app.server.organization
    })
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(e.message)
  end

  private

end
