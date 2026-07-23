class DeploymentsController < ApplicationController
  include OperatorOnly # members may view (GET); only operators may roll back (POST)
  before_action :set_deployment

  def show
    @app = @deployment.app
  end

  # Roll the app back to this deployment's release. Kamal only for now — it boots
  # the prior versioned image Kamal still retains on the host (no rebuild).
  def rollback
    app = @deployment.app

    unless app.kamal?
      return redirect_to app, alert: "Rollback is only supported for Kamal apps for now (this app uses #{app.deploy_method})."
    end
    unless @deployment.rollback_target?
      return redirect_to app, alert: "That release can't be rolled back to — it's the current release, or has no recorded version."
    end
    if app.deployments.in_progress.any?
      return redirect_to app, alert: "A deployment is already in progress."
    end

    version = @deployment.target_version
    rollback = app.deployments.create!(
      user: current_user, server: app.server,
      kind: "rollback", commit_sha: version, release_version: version
    )
    RollbackAppJob.perform_later(rollback.id, version)
    redirect_to app, notice: "Rolling back #{app.name} to #{version.first(12)} — watch the deploy log."
  end

  private

  def set_deployment
    # Only deployments of the current org's apps — a foreign id 404s.
    @deployment = Deployment.where(app_id: current_organization.apps.select(:id)).find(params[:id])
  end
end
