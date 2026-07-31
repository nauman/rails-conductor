class RollbackAppJob < ApplicationJob
  queue_as :default

  # Roll an app back to a previously-shipped release.
  #
  # Kamal and docker both support this now. Docker only became possible once the
  # deploy path started tagging images by SHA and retaining them (ADR 0003) —
  # before that every build was `:latest` and the previous image was pruned, so
  # there was no artifact to return to.
  #
  # Native still has no rollback action: it retains release directories, so the
  # substrate exists, but relinking + restarting + verifying is not built. Fail
  # loud rather than silently no-op.
  def perform(deployment_id, version)
    deployment = Deployment.find(deployment_id)
    app = deployment.app

    case app.deploy_method
    when "kamal"  then KamalDeployer.new(app, deployment).rollback!(version)
    when "docker" then DockerRollback.new(app, deployment).rollback!(version)
    else
      deployment.fail!("Rollback is not supported for #{app.deploy_method} deploys yet. " \
                       "Release-dir rollback for native apps is not built.")
    end
  end
end
