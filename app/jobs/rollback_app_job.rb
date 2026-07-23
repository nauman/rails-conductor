class RollbackAppJob < ApplicationJob
  queue_as :default

  # Roll an app back to a previously-shipped release. Only Kamal supports this
  # today (Kamal retains prior versioned images on the host); native/docker have
  # no retained artifact yet — fail loud rather than silently no-op.
  def perform(deployment_id, version)
    deployment = Deployment.find(deployment_id)
    app = deployment.app

    unless app.kamal?
      deployment.fail!("Rollback is only supported for Kamal deploys (this app uses #{app.deploy_method}). " \
                       "Release-dir rollback for native/docker is not built yet.")
      return
    end

    KamalDeployer.new(app, deployment).rollback!(version)
  end
end
