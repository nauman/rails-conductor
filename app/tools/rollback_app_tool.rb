class RollbackAppTool
  include ActorScoped

  DEFINITION = {
    name: "rollback_app",
    description: "Roll a Kamal app back to a previously-shipped release. Boots the prior image Kamal still " \
      "retains on the host — no rebuild. Targets the deployment given by deployment_id, or the release before " \
      "the current one if omitted. Kamal-only; native/docker have no retained release yet.",
    input_schema: {
      type: "object",
      properties: {
        app_id:        { type: "integer", description: "The app to roll back (or app_name)" },
        app_name:      { type: "string",  description: "The app to roll back (or app_id)" },
        deployment_id: { type: "integer", description: "The prior deployment whose release to roll back to. Omit to roll back to the release before the current one." }
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
    return Result.fail("Rollback is only supported for Kamal apps (this app uses #{app.deploy_method}).") unless app.kamal?

    target = target_deployment(app, input["deployment_id"] || input[:deployment_id])
    return Result.fail("No prior release to roll back to for #{app.name}.") unless target
    return Result.fail("That release can't be rolled back to — it's the current release, or has no recorded version.") unless target.rollback_target?
    return Result.fail("A deployment is already in progress for #{app.name}.") if app.deployments.in_progress.any?

    version = target.target_version
    rollback = app.deployments.create!(
      user: @user, server: app.server,
      kind: "rollback", commit_sha: version, release_version: version
    )
    RollbackAppJob.perform_later(rollback.id, version)

    Result.ok({
      deployment_id:  rollback.id,
      app:            app.name,
      status:         "started",
      rolled_back_to: version,
      message:        "Rolling back #{app.name} to release #{version.to_s.first(12)}. Deployment ID: #{rollback.id}",
      _organization:  app.organization || app.server.organization
    })
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(e.message)
  end

  private

  # Explicit target by id, else the release before the current one (the natural
  # "roll back one"): rollbackable is newest-first, so offset(1) skips the current.
  def target_deployment(app, deployment_id)
    if deployment_id.present?
      app.deployments.find_by(id: deployment_id)
    else
      app.deployments.rollbackable.offset(1).first
    end
  end
end
