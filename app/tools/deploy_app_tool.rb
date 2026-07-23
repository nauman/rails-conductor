class DeployAppTool
  include ActorScoped

  DEFINITION = {
    name: 'deploy_app',
    description: "Deploy an app to the latest commit on origin/<branch> — the REMOTE, not any local checkout. Push your commits first; unpushed local work is NOT shipped. Creates a Deployment (dispatched by deploy_method: native, docker, or kamal); the resolved commit is recorded as commit_sha — verify it matches your intended commit.",
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
        },
        force: {
          type: 'boolean',
          description: 'Deploy past a blocking preflight (at-risk server audit or deploy hold). Default false — confirm with the user before forcing.'
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

    # Single-flight + preflight gate: a duplicate trigger returns already_running
    # (the DB invariant guarantees exactly one), and a blocking preflight (at-risk
    # server / deploy hold) refuses unless force: true.
    # A safety override must be an explicit literal boolean. The tool registry does
    # not enforce the JSON schema, and ActiveModel would coerce "no"/"banana"→true —
    # so validate strictly and reject anything that isn't a real boolean.
    raw_force = input["force"].nil? ? input[:force] : input["force"]
    unless raw_force.nil? || raw_force == true || raw_force == false
      return Result.fail("`force` must be a boolean (true or false); got #{raw_force.inspect}.")
    end
    force = raw_force == true

    deployment, status, preflight = app.start_deployment!(user: @user, force: force)

    if status == :blocked
      blockers = preflight.checks.select { |c| c.status == :fail }
      return Result.ok({
        app:           app.name,
        status:        'blocked',
        message:       "Deploy blocked by preflight for #{app.name}. Resolve the blockers or re-call with force: true.",
        preflight:     preflight_payload(preflight),
        blockers:      blockers.map { |c| "#{c.label}: #{c.detail}" },
        _organization: app.organization || app.server.organization
      })
    end

    if status == :already_running
      return Result.ok({
        deployment_id: deployment&.id,
        app:           app.name,
        status:        'already_running',
        message:       "A deployment is already in progress for #{app.name}. Deployment ID: #{deployment&.id}.",
        _organization: app.organization || app.server.organization
      })
    end

    branch = app.branch.presence || "main"
    Result.ok({
      deployment_id: deployment.id,
      app:           app.name,
      server:        app.server.name,
      deploy_method: app.deploy_method,
      branch:        branch,
      status:        'started',
      message:       "Deploying #{app.name} (#{app.deploy_method}) on #{app.server.name}. Deployment ID: #{deployment.id}",
      # Conductor builds from the REMOTE (origin/<branch>), not any local checkout —
      # unpushed commits are NOT shipped. The resolved SHA is recorded as commit_sha.
      ships_from:    "origin/#{branch}",
      verify:        "Confirm the shipped commit: conductor_read action=deployment (deployment_id: #{deployment.id}) → commit_sha should match your intended commit. If you committed locally, push first.",
      preflight:     preflight_payload(preflight),
      # _organization: the org this call touched. The MCP controller reads this to
      # log the affected org on the McpCall, then strips it before responding.
      _organization: app.organization || app.server.organization
    })
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(e.message)
  end

  private

  def preflight_payload(preflight)
    return nil unless preflight

    {
      status: preflight.status,
      checks: preflight.checks.map { |c| { key: c.key, status: c.status, detail: c.detail } }
    }
  end
end
