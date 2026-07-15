class DeploymentsController < ApplicationController
  def show
    # Only deployments of the current org's apps — a foreign id 404s.
    @deployment = Deployment.where(app_id: current_organization.apps.select(:id)).find(params[:id])
    @app = @deployment.app
  end
end
