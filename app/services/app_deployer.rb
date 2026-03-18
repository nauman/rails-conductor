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

  def run(command)
    log "> #{command}"
    ssh.execute(command)
    if ssh.success?
      log ssh.output if ssh.output.present?
      true
    else
      log "FAILED: #{ssh.error}"
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
    run("mkdir -p #{app_dir}")

    # Check if repo exists
    if run("test -d #{app_dir}/.git && echo 'exists'") && ssh.output&.include?("exists")
      # Pull latest
      run("cd #{app_dir} && git fetch origin && git reset --hard origin/#{app.branch}")
    else
      # Clone fresh
      run("rm -rf #{app_dir} && git clone --branch #{app.branch} --depth 1 #{app.repository_url} #{app_dir}")
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
    env_flags = app.env_variables.map(&:to_docker_env).join(" ")
    port = app.port || 3000

    docker_run = [
      "docker run -d",
      "--name #{app.container_name}",
      "--restart unless-stopped",
      "-p #{port}:#{port}",
      env_flags,
      "-e PORT=#{port}",
      "-e RAILS_ENV=production",
      "-e RAILS_LOG_TO_STDOUT=true",
      "#{app.image_name}:latest"
    ].join(" ")

    if run(docker_run)
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
