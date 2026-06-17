require "base64"

# Deploys a kamal-managed app by SSHing to its server, syncing a server-side
# checkout of the repo to the target branch, generating `.kamal/secrets` from
# Conductor's env vars, and running `kamal deploy` there (the build happens on
# the box). Mirrors NativeDeployer's stream-over-SSH + broadcast pattern. The
# app's EnvVariables are both written to `.kamal/secrets` (Kamal's secret source)
# and exported — so Conductor's UI / `set_env_variable` are the source of truth
# for a kamal app's secret values (e.g. SECRET_KEY_BASE, DATABASE_URL).
class KamalDeployer
  attr_reader :app, :deployment, :ssh, :error

  def initialize(app, deployment)
    @app = app
    @deployment = deployment
    @ssh = SshConnection.new(app.server)
  end

  def deploy!
    deployment.start!
    log "Starting Kamal deployment for #{app.name}"

    return fail_with("Server SSH not configured") unless app.server&.ssh_configured?
    return fail_with("App has no repository_url") if app.repository_url.blank?

    deployment.mark_deploying!
    result = ssh.execute_stream(build_script) do |_type, data|
      data.each_line { |line| log(line.chomp) }
    end

    if result[:success]
      deployment.succeed!
      log "Kamal deployment completed successfully!"
      broadcast_status("succeeded")
      true
    else
      fail_with("kamal deploy failed (exit code #{result[:exit_code]})")
    end
  rescue => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  # Idempotent: clones on first deploy, otherwise hard-resets to the latest
  # commit on the branch, generates `.kamal/secrets` from Conductor's env vars,
  # then runs Kamal from the repo dir. Prefers the bundled `bin/kamal`, falling
  # back to a `kamal` on PATH.
  def build_script
    dir    = app.app_dir
    branch = app.branch.presence || "main"

    <<~BASH
      set -e
      if [ ! -d #{esc(dir)}/.git ]; then
        mkdir -p #{esc(dir)}
        git clone #{esc(app.repository_url)} #{esc(dir)}
      fi
      cd #{esc(dir)}
      git fetch origin
      git checkout #{esc(branch)}
      git reset --hard origin/#{esc(branch)}
      #{write_secrets_file}
      #{env_exports}
      if [ -x bin/kamal ]; then KAMAL=./bin/kamal; else KAMAL=kamal; fi
      $KAMAL deploy
    BASH
  end

  # Generate .kamal/secrets from Conductor's env vars (base64 so values survive
  # shell quoting and aren't human-readable in the script). The deploy log streams
  # command OUTPUT, not the script itself, so the values don't leak into the log.
  def write_secrets_file
    content = KamalEnvWriter.secrets_content(app)
    return "" if content.strip.empty?

    encoded = Base64.strict_encode64(content)
    "mkdir -p .kamal\n" \
      "echo #{esc(encoded)} | base64 --decode > .kamal/secrets"
  end

  def env_exports
    app.env_variables.map { |var| "export #{var.key}=#{esc(var.value)}" }.join("\n")
  end

  def esc(value)
    "'#{value.to_s.gsub("'", "'\\''")}'"
  end

  def log(message)
    deployment.append_log(message)
    broadcast(message)
    Rails.logger.info "[KamalDeploy:#{app.slug}] #{message}"
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
