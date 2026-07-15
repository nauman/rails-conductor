class ScriptRunsController < ApplicationController
  def show
    # Only script runs on the current org's servers — a foreign id 404s.
    @script_run = ScriptRun.where(server_id: current_organization.servers.select(:id)).find(params[:id])
  end
end
