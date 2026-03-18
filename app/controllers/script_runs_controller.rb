class ScriptRunsController < ApplicationController
  def show
    @script_run = ScriptRun.find(params[:id])
  end
end
