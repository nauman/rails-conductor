class DeployAppJob < ApplicationJob
  queue_as :default

  def perform(deployment_id)
    deployment = Deployment.find(deployment_id)
    app = deployment.app

    return if reentrant_self_deploy?(app, deployment)

    deployer =
      case app.deploy_method
      when "native" then NativeDeployer.new(app, deployment)
      when "kamal"  then KamalDeployer.new(app, deployment)
      else AppDeployer.new(app, deployment)
      end
    deployer.deploy!
  end

  private

  # Self-deploy re-entry guard — the fix for the self-deploy loop + false emails.
  #
  # When Conductor deploys ITSELF, kamal boots the new release and stops the old
  # container — SIGTERM'ing the worker running THIS job, right after the new
  # release is already live. SolidQueue then re-runs the interrupted job. A re-run
  # that invokes kamal again re-rolls the container (killing itself again → loop),
  # races the deploy lock, and emails false failures.
  #
  # A freshly-created deployment is "pending" until deploy! calls start!. So a
  # self-managed deployment in ANY other state (building / deploying / succeeded /
  # failed / cancelled) is a re-run of a job whose first execution already ran —
  # NOT a fresh deploy. Bail. This must include the terminal states, not just
  # "deploying": SelfDeployReconciler finalizes the row to "succeeded" on the new
  # container's boot, and a guard that only caught "deploying" let the next re-run
  # slip past a "succeeded" row and start a brand-new roll — an infinite handoff
  # between the reconciler and the job. Only "pending" proceeds; the reconciler
  # owns finalization of everything else.
  def reentrant_self_deploy?(app, deployment)
    return false unless app.self_managed?
    return false if deployment.status == "pending"

    deployment.append_log(
      "DeployAppJob re-entered for a self-managed deploy in state " \
      "'#{deployment.status}' — not re-running kamal (a re-run would re-roll and " \
      "loop). SelfDeployReconciler owns finalization of this row."
    )
    true
  end
end
