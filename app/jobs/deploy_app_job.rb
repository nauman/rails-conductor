class DeployAppJob < ApplicationJob
  queue_as :default

  def perform(deployment_id)
    deployment = Deployment.find(deployment_id)
    app = deployment.app

    return if reentrant_self_deploy_midroll?(app, deployment)

    deployer =
      case app.deploy_method
      when "native" then NativeDeployer.new(app, deployment)
      when "kamal"  then KamalDeployer.new(app, deployment)
      else AppDeployer.new(app, deployment)
      end
    deployer.deploy!
  end

  private

  # Self-deploy re-entry guard — the fix for the false "deploy failed" emails.
  #
  # When Conductor deploys ITSELF, kamal boots the new release and then stops the
  # old container — SIGTERM'ing the worker running THIS job, right AFTER the new
  # release is already live and serving. SolidQueue then re-runs the interrupted
  # job. That re-run would invoke kamal again, collide on the deploy lock
  # ("Deploy lock found"), mark the deployment failed, and fire a failure email —
  # a FALSE alarm, because the new release is up. SelfDeployReconciler already
  # finalizes the row to succeeded when the new container boots (it matches the
  # live KAMAL_VERSION to this row's sha).
  #
  # So: if a self-managed deployment has already entered the release swap
  # ("deploying"), don't re-run kamal. Let the reconciler close it out. A genuine
  # early failure (before the swap) still runs and still alerts.
  def reentrant_self_deploy_midroll?(app, deployment)
    return false unless app.self_managed? && deployment.status == "deploying"

    deployment.append_log(
      "DeployAppJob re-entered while this self-managed deploy is mid-roll — not " \
      "re-running kamal (a re-run would race the deploy lock and email a false " \
      "failure). The new release reconciles this deployment when it boots."
    )
    true
  end
end
