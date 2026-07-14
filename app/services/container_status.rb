require "shellwords"

class ContainerStatus
  attr_reader :app, :error

  def initialize(app)
    @app = app
    @error = nil
  end

  def sync!
    return failure("No server configured") unless app.server.present?
    return failure("Server SSH not configured") unless app.server.ssh_configured?

    app.kamal? ? sync_kamal : sync_docker
  rescue JSON::ParserError => e
    app.update_container_status!("unknown", error: "Failed to parse container state")
    failure("Failed to parse container state: #{e.message}")
  rescue => e
    app.update_container_status!("unknown", error: e.message)
    failure("Unexpected error: #{e.message}")
  end

  def success?
    @error.nil?
  end

  private

  # Docker/native apps: inspect the conductor-<slug> container directly.
  def sync_docker
    ssh = SshConnection.new(app.server)
    result = ssh.execute("docker inspect --format '{{json .State}}' #{app.container_name} 2>/dev/null")

    if ssh.success? && result.present?
      parse_and_update(result)
    elsif ssh.success? && app.status == "stopped"
      # SSH worked; there's simply no container — which is exactly right for an
      # app we deliberately stopped. Record a clean stopped state, not a failure.
      app.update!(container_status: "exited", last_status_check_at: Time.current, status_check_error: nil)
      true
    else
      app.update_container_status!("unknown", error: ssh.error || "Container not found")
      failure(ssh.error || "Container not found")
    end
  end

  # Kamal apps: the container is named <service>-web-<version> and labelled
  # `service=<service>`, so we detect it by label rather than by name. A running
  # container means the app is live — reconcile App.status too (a Kamal deploy
  # may have happened out-of-band, bypassing Conductor's deployer).
  def sync_kamal
    ssh = SshConnection.new(app.server)
    filter = "label=service=#{Shellwords.escape(app.kamal_service)}"
    # CreatedAt lets us tell whether the running release is newer than a failed
    # deploy (so we don't cry "still serving the previous release" forever).
    running = ssh.execute("docker ps --filter #{filter} --filter status=running --format '{{.CreatedAt}}'")

    unless ssh.success?
      app.update_container_status!("unknown", error: ssh.error || "docker ps failed")
      return failure(ssh.error || "docker ps failed")
    end

    if running.to_s.strip.present?
      started_at = parse_docker_created(running)
      app.update!(status: "running", container_status: "running", container_started_at: started_at,
                  last_status_check_at: Time.current, status_check_error: failed_deploy_note(started_at))
    else
      app.update!(status: "stopped", container_status: "exited",
                  last_status_check_at: Time.current, status_check_error: nil)
    end
    true
  end

  # A container is up, but if the LATEST deployment failed we're serving the
  # PREVIOUS release — surface that instead of a clean green "running". BUT if
  # the running container is newer than that failed deploy, a later deploy
  # (often out-of-band, e.g. Conductor self-deploying via CI) already replaced
  # it, so the old failure is stale — don't report it.
  def failed_deploy_note(container_started_at = nil)
    dep = app.last_deployment
    return nil unless dep&.failed?
    return nil if container_started_at && dep.completed_at && container_started_at > dep.completed_at

    when_failed = dep.completed_at ? " (#{dep.completed_at.strftime('%b %-d %H:%M UTC')})" : ""
    "Last deploy failed#{when_failed} — still serving the previous release."
  end

  # docker's CreatedAt looks like "2026-07-14 04:15:32 +0000 UTC" (possibly
  # several lines if multiple containers match — take the newest).
  def parse_docker_created(output)
    output.to_s.lines.filter_map { |line| Time.parse(line.strip.sub(/\s+UTC\z/, "")) rescue nil }.max
  end

  def parse_and_update(json_output)
    state = JSON.parse(json_output.strip)

    status = state["Status"]&.downcase || "unknown"
    started_at = parse_docker_time(state["StartedAt"])

    app.update_container_status!(status, started_at: started_at)
    true
  rescue => e
    failure("Failed to update status: #{e.message}")
  end

  def parse_docker_time(time_str)
    return nil if time_str.blank? || time_str == "0001-01-01T00:00:00Z"
    Time.parse(time_str)
  rescue
    nil
  end

  def failure(message)
    @error = message
    false
  end
end
