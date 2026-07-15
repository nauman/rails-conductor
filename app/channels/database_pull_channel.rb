class DatabasePullChannel < ApplicationCable::Channel
  def subscribed
    # Only DB pulls in the connected user's organizations.
    pull = DatabasePull.where(organization_id: current_user.organizations.ids).find_by(id: params[:database_pull_id])
    pull ? stream_from("database_pull_#{pull.id}") : reject
  end

  def unsubscribed
    stop_all_streams
  end
end
