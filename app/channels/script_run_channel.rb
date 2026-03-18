class ScriptRunChannel < ApplicationCable::Channel
  def subscribed
    run = ScriptRun.find_by(id: params[:script_run_id])
    if run
      stream_from "script_run_#{run.id}"
    else
      reject
    end
  end

  def unsubscribed
    stop_all_streams
  end
end
