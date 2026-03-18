class DeployChannel < ApplicationCable::Channel
  def subscribed
    deployment = Deployment.find_by(id: params[:deployment_id])
    if deployment
      stream_from "deployment_#{deployment.id}"
    else
      reject
    end
  end

  def unsubscribed
    stop_all_streams
  end
end
