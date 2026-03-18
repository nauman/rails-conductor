class NativeDeployer
  attr_reader :app, :deployment, :ssh, :error

  def initialize(app, deployment)
    @app = app
    @deployment = deployment
    @ssh = SshConnection.new(app.server)
  end

  def deploy!
    deployment.start!
    log "Starting native deployment for #{app.name}"

    unless app.server&.ssh_configured?
      return fail_with("Server SSH not configured")
    end

    if first_deploy?
      log "First deploy detected — running setup"
      return unless run_script("app-setup", "Setting up app directory")
      return unless run_script("systemd-setup", "Configuring systemd service")
    end

    return unless run_script("app-deploy", "Deploying release")
    return unless health_check

    deployment.succeed!
    log "Native deployment completed successfully!"
    broadcast_status("succeeded")
    true
  rescue => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  def first_deploy?
    app.deployed_at.nil?
  end

  def run_script(script_name, step_label)
    script = Script.find_by(name: script_name)
    unless script
      return fail_with("Built-in script '#{script_name}' not found")
    end

    log "Running: #{step_label}"
    deployment.mark_deploying!

    script_body = env_exports + script.body
    result = ssh.execute_stream(script_body) do |type, data|
      data.each_line { |line| log(line.chomp) }
    end

    if result[:success]
      log "#{step_label} completed (exit code #{result[:exit_code]})"
      true
    else
      fail_with("#{step_label} failed (exit code #{result[:exit_code]})")
      false
    end
  end

  def health_check
    return true if app.health_check_path.blank?

    port = app.port || 3000
    url = "http://localhost:#{port}#{app.health_check_path}"
    log "Waiting for health check at #{url}"

    6.times do |i|
      sleep 10
      result = ssh.execute("curl -sf #{url} > /dev/null && echo 'healthy'")
      if ssh.success? && ssh.output&.include?("healthy")
        log "Health check passed!"
        return true
      end
      log "Health check attempt #{i + 1}/6 failed, retrying..."
    end

    fail_with("Health check failed after 60 seconds")
    false
  end

  def env_exports
    exports = []
    exports << "export APP_NAME=#{escape(app.slug)}"
    exports << "export REPO_URL=#{escape(app.repository_url)}"
    exports << "export BRANCH=#{escape(app.branch || 'main')}"
    exports << "export BASE_DIR=#{escape(app.app_dir)}"

    app.env_variables.each do |var|
      exports << "export #{var.key}=#{escape(var.value)}"
    end

    exports.join("\n") + "\n"
  end

  def escape(value)
    "'#{value.to_s.gsub("'", "'\\''")}'"
  end

  def log(message)
    deployment.append_log(message)
    broadcast(message)
    Rails.logger.info "[NativeDeploy:#{app.slug}] #{message}"
  end

  def broadcast(message)
    timestamp = Time.current.strftime("%H:%M:%S")
    ActionCable.server.broadcast(
      "deployment_#{deployment.id}",
      { type: "log", line: "[#{timestamp}] #{message}\n", status: deployment.status }
    )
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
end
