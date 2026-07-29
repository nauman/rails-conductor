# Runs the provision-&-harden orchestration off the request cycle (it can take a
# couple of minutes: apt installs, a Postgres restart, an sshd reload). Records
# the outcome + the per-step trace so a timed-out or backgrounded call is still
# inspectable, and HardenServer's own final re-audit updates the grade.
class HardenServerJob < ApplicationJob
  queue_as :ops

  def perform(server_id)
    server = Server.find_by(id: server_id)
    return unless server

    result = HardenServer.new(server).call

    server.update!(
      last_harden_status: result.ok? ? "succeeded" : "failed",
      last_harden_at:     Time.current,
      last_harden_log:    { steps: result.steps, audit: result.audit_status, error: result.error }.to_json
    )
  end
end
