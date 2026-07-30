class AppDeployer
  attr_reader :app, :deployment, :ssh, :error

  def initialize(app, deployment)
    @app = app
    @deployment = deployment
    @ssh = SshConnection.new(app.server)
  end

  def deploy!
    deployment.start!
    log "Starting deployment for #{app.name}"

    unless app.server&.ssh_configured?
      return fail_with("Server SSH not configured")
    end

    steps = [
      :ensure_docker,
      :clone_or_pull_repo,
      :build_image,
      :stop_old_container,
      :start_container,
      :health_check,
      :cleanup
    ]

    steps.each do |step|
      log "Running: #{step.to_s.humanize}"
      unless send(step)
        return fail_with("Step failed: #{step}")
      end
    end

    deployment.succeed!
    log "Deployment completed successfully!"
    broadcast_status("succeeded")
    true
  rescue => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  def log(message)
    deployment.append_log(message)
    broadcast(message)
    Rails.logger.info "[Deploy:#{app.slug}] #{message}"
  end

  def broadcast(message)
    timestamp = Time.current.strftime("%H:%M:%S")
    ActionCable.server.broadcast(
      "deployment_#{deployment.id}",
      { type: "log", line: "[#{timestamp}] #{message}\n", status: deployment.status }
    )
  end

  # `display` is what gets logged/broadcast — pass a redacted variant for any
  # command that embeds secrets, so decrypted values never reach the log.
  # Decide success from the command's EXIT STATUS, not from whether it wrote to
  # stderr. git writes normal progress ("Cloning into '…'") to stderr even on
  # exit 0, so the old exec!-based path could neither see a real failure nor
  # trust a real success — execute_with_status captures the exit code and keeps
  # stderr as log output.
  def run(command, display: command)
    log "> #{display}"
    result = ssh.execute_with_status(command)
    if result[:success]
      log result[:output] if result[:output].present?
      true
    else
      log "FAILED (exit #{result[:exit_code]}): #{result[:stderr].presence || result[:output]}"
      false
    end
  end

  def fail_with(message)
    @error = message
    deployment.fail!(message)
    broadcast_status("failed")
    false
  end

  def broadcast_status(status)
    ActionCable.server.broadcast(
      "deployment_#{deployment.id}",
      { type: "status", status: status }
    )
  end

  def app_dir
    "/opt/conductor/apps/#{app.slug}"
  end

  def ensure_docker
    run("which docker || (curl -fsSL https://get.docker.com | sh)")
  end

  def clone_or_pull_repo
    return false unless run("mkdir -p #{app_dir}")

    # Deploy the exact commit recorded on the deployment when one was given (e.g.
    # a webhook's `after` sha) so the audit trail matches what actually shipped —
    # not whatever HEAD happens to be. Fall back to the branch tip otherwise.
    target = deployment.commit_sha.presence || "origin/#{app.branch}"

    # Probe existence with a command that always exits 0 (a missing checkout is
    # not a failure), then branch on the output.
    run("test -d #{app_dir}/.git && echo exists || echo missing")
    if ssh.output.to_s.include?("exists")
      run("cd #{app_dir} && git fetch origin && git reset --hard #{target}")
    else
      # Return the CLONE's real result — never leak the `nil` from a trailing
      # `... if commit_sha.present?` on a first deploy (commit_sha is null then),
      # which is what falsely failed the step even though the clone succeeded.
      return false unless run("rm -rf #{app_dir} && git clone --branch #{app.branch} #{app.repository_url} #{app_dir}")

      deployment.commit_sha.present? ? run("cd #{app_dir} && git reset --hard #{target}") : true
    end
  end

  def build_image
    deployment.mark_deploying!

    dockerfile = app.dockerfile_path || "Dockerfile"
    build_cmd = "cd #{app_dir} && docker build -t #{app.image_name}:latest -f #{dockerfile} ."
    run(build_cmd)
  end

  def stop_old_container
    # Stop and remove old container if exists (don't fail if not found)
    run("docker stop #{app.container_name} 2>/dev/null || true")
    run("docker rm #{app.container_name} 2>/dev/null || true")
    true
  end

  def start_container
    port = app.port || 3000

    prefix = [
      "docker run -d",
      "--name #{app.container_name}",
      "--restart unless-stopped",
      "-p #{port}:#{port}"
    ]
    suffix = [
      "-e PORT=#{port}",
      "-e RAILS_ENV=production",
      "-e RAILS_LOG_TO_STDOUT=true",
      "#{app.image_name}:latest"
    ]
    docker_run = (prefix + [ app.env_variables.map(&:to_docker_env).join(" ") ] + suffix).join(" ")
    # Redact secret env values in the logged/broadcast copy.
    display    = (prefix + [ app.env_variables.map(&:to_docker_env_redacted).join(" ") ] + suffix).join(" ")

    if run(docker_run, display: display)
      # Get container ID
      run("docker ps -q -f name=#{app.container_name}")
      if ssh.output.present?
        app.update!(container_id: ssh.output.strip)
        true
      else
        false
      end
    else
      false
    end
  end

  def health_check
    return true if app.health_check_path.blank?

    port = app.port || 3000
    url = "http://localhost:#{port}#{app.health_check_path}"

    # Wait for container to be ready (max 60 seconds)
    log "Waiting for health check at #{url}"

    6.times do |i|
      sleep 10
      if run("curl -sf #{url} > /dev/null && echo 'healthy'") && ssh.output&.include?("healthy")
        log "Health check passed!"
        return true
      end
      log "Health check attempt #{i + 1}/6 failed, retrying..."
    end

    log "Health check failed after 60 seconds"
    false
  end

  def cleanup
    # Remove dangling images
    run("docker image prune -f 2>/dev/null || true")
    true
  end
end
