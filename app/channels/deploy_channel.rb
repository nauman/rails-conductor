class DeployChannel < ApplicationCable::Channel
  def subscribed
    # Only deployments of apps in the connected user's organizations.
    scope = App.where(organization_id: current_user.organizations.ids).select(:id)
    deployment = Deployment.where(app_id: scope).find_by(id: params[:deployment_id])
    deployment ? stream_from("deployment_#{deployment.id}") : reject
  end

  def unsubscribed
    stop_all_streams
  end
end
