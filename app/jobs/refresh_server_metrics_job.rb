class RefreshServerMetricsJob < ApplicationJob
  queue_as :ops

  CONNECTION_ATTEMPTS = 2

  limits_concurrency(
    key: ->(server_id = nil) { server_id ? "server:#{server_id}" : "metrics-fanout" },
    group: "ServerSshProbe",
    duration: 2.minutes
  )

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
    CONNECTION_ATTEMPTS.times do |attempt|
      return if metrics_service.fetch_and_update!
      break unless connection_failure?(metrics_service.error)
      break if attempt == CONNECTION_ATTEMPTS - 1

      Rails.logger.info "Retrying metrics connection to #{server.name} after timeout"
    end

    Rails.logger.warn "Failed to refresh metrics for #{server.name}: #{metrics_service.error}"
    server.record_metrics_failure! if connection_failure?(metrics_service.error)
  end

  def refresh_all_servers
    Server.with_ssh.find_each do |server|
      RefreshServerMetricsJob.perform_later(server.id)
    end
  end

  def connection_failure?(error)
    error.to_s.include?("Connection")
  end
end
