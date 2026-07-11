class ApplyUpdatesJob < ApplicationJob
  queue_as :ops

  def perform(server_id, scope)
    server = Server.find_by(id: server_id)
    return unless server

    result = SystemUpdater.new(server, scope: scope).apply

    server.update!(
      last_update_status: result.success? ? "succeeded" : "failed",
      last_update_scope:  scope,
      last_update_log:    (result.output.presence || result.error).to_s.last(20_000),
      last_update_at:     Time.current
    )
  end
end
