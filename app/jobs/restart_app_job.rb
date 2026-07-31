require "shellwords"

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

    ssh.execute(restart_command(app))
    no_container = ssh.output.to_s.include?("NO_CONTAINER")

    if ssh.success? && !no_container
      app.update!(status: "running")
      Rails.logger.info "Successfully restarted container for #{app.name}"
    else
      err = no_container ? "no container found to restart" : ssh.error
      Rails.logger.warn "Failed to restart container for #{app.name}: #{err}"
      app.update_container_status!("unknown", error: err)
    end

    SyncContainerStatusJob.perform_later(app.id)
  end

  # Shared with the UI's Stop button — see ContainerCommand for why a Kamal
  # app cannot be reached by a fixed container name.
  def restart_command(app)
    ContainerCommand.restart(app)
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
