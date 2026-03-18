class RestartAppJob < ApplicationJob
  queue_as :default

  def perform(app_id)
    app = App.find_by(id: app_id)
    return unless app&.server&.ssh_configured?

    ssh = SshConnection.new(app.server)

    if app.native?
      restart_native(app, ssh)
    else
      restart_docker(app, ssh)
    end
  rescue => e
    Rails.logger.error "Error restarting app #{app_id}: #{e.message}"
    app&.update_container_status!("unknown", error: e.message)
  end

  private

  def restart_docker(app, ssh)
    app.update_container_status!("restarting")

    ssh.execute("docker restart #{app.container_name}")

    if ssh.success?
      app.update!(status: "running")
      Rails.logger.info "Successfully restarted container for #{app.name}"
    else
      Rails.logger.warn "Failed to restart container for #{app.name}: #{ssh.error}"
      app.update_container_status!("unknown", error: ssh.error)
    end

    SyncContainerStatusJob.perform_later(app.id)
  end

  def restart_native(app, ssh)
    ssh.execute("systemctl --user restart #{app.service_name}")

    if ssh.success?
      app.update!(status: "running")
      Rails.logger.info "Successfully restarted #{app.service_name} for #{app.name}"
    else
      Rails.logger.warn "Failed to restart #{app.service_name} for #{app.name}: #{ssh.error}"
      app.update!(status: "failed")
    end
  end
end
