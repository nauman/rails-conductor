# Reap a stuck in-progress deployment so the app can deploy again. A job-retry
# race (or a killed worker) can orphan a deployment at "deploying" with no process
# driving it; the one-active-deploy-per-app index then blocks every future deploy.
# This flips that record to the terminal `cancelled` state. It does NOT touch the
# running container — a subsequent deploy reconciles it — only the stale record.
class CancelDeploymentAppTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    deployment = find_target(input)
    return Result.fail("Deployment not found. Provide deployment_id, or app_id/app_name for its latest in-progress one.") unless deployment

    unless deployment.in_progress?
      return Result.fail("Deployment ##{deployment.id} is #{deployment.status}, not in progress — nothing to cancel.")
    end

    deployment.cancel!
    Result.ok(
      deployment_id: deployment.id, app: deployment.app&.name, status: deployment.status,
      message: "Deployment ##{deployment.id} reaped (cancelled) — #{deployment.app&.name} can deploy again.",
      _organization: deployment.app&.organization
    )
  end

  private

  def find_target(input)
    if input["deployment_id"].present?
      visible_deployments.find_by(id: input["deployment_id"])
    elsif (app = find_app(input))
      app.deployments.in_progress.order(created_at: :desc).first
    end
  end
end
