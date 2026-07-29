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

  # A plain docker app runs as conductor-<slug>. A Kamal app does NOT — its
  # container is <service>-<role>-<version> and is located by the `service` label
  # (the same lookup logs/status use), so restart by resolving the live container
  # id (including a stopped one, hence `ps -a`) rather than a fixed name that
  # would never match. Emits NO_CONTAINER when nothing matches.
  def restart_command(app)
    return "docker restart #{Shellwords.escape(app.container_name)}" unless app.kamal?

    cands = app.kamal_service_candidates.map { |c| Shellwords.escape(c) }.join(" ")
    %(cid=""; for s in #{cands}; do cid=$(docker ps -aq -f "label=service=$s" | head -n1); [ -n "$cid" ] && break; done; ) +
      %(if [ -n "$cid" ]; then docker restart "$cid"; else echo NO_CONTAINER; fi)
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
