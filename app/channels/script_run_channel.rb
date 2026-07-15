class ScriptRunChannel < ApplicationCable::Channel
  def subscribed
    # Only script runs on servers in the connected user's organizations.
    scope = Server.where(organization_id: current_user.organizations.ids).select(:id)
    run = ScriptRun.where(server_id: scope).find_by(id: params[:script_run_id])
    run ? stream_from("script_run_#{run.id}") : reject
  end

  def unsubscribed
    stop_all_streams
  end
end
