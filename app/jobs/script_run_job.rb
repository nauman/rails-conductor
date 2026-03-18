class ScriptRunJob < ApplicationJob
  queue_as :default

  def perform(script_run_id)
    script_run = ScriptRun.find(script_run_id)
    ProvisioningService.new(script_run).run
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("ScriptRunJob: ScriptRun #{script_run_id} not found")
  end
end
