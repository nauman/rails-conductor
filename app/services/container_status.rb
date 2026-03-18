class ContainerStatus
  attr_reader :app, :error

  def initialize(app)
    @app = app
    @error = nil
  end

  def sync!
    return failure("No server configured") unless app.server.present?
    return failure("Server SSH not configured") unless app.server.ssh_configured?

    ssh = SshConnection.new(app.server)
    result = ssh.execute("docker inspect --format '{{json .State}}' #{app.container_name} 2>/dev/null")

    if ssh.success? && result.present?
      parse_and_update(result)
    else
      # Container might not exist
      app.update_container_status!("unknown", error: ssh.error || "Container not found")
      @error = ssh.error || "Container not found"
      false
    end
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
