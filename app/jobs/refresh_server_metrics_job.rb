class RefreshServerMetricsJob < ApplicationJob
  queue_as :ops

  def perform(server_id = nil)
    if server_id
      refresh_single_server(server_id)
    else
      refresh_all_servers
    end
  end

  private

  def refresh_single_server(server_id)
    server = Server.find_by(id: server_id)
    return unless server&.ssh_configured?

    metrics_service = ServerMetrics.new(server)
    unless metrics_service.fetch_and_update!
      Rails.logger.warn "Failed to refresh metrics for #{server.name}: #{metrics_service.error}"
      server.mark_offline! if metrics_service.error.include?("Connection")
    end
  end

  def refresh_all_servers
    Server.with_ssh.find_each do |server|
      RefreshServerMetricsJob.perform_later(server.id)
    end
  end
end
