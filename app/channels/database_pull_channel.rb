class DatabasePullChannel < ApplicationCable::Channel
  def subscribed
    pull = DatabasePull.find_by(id: params[:database_pull_id])
    if pull
      stream_from "database_pull_#{pull.id}"
    else
      reject
    end
  end

  def unsubscribed
    stop_all_streams
  end
end
