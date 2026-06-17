require "shellwords"
require "fileutils"
require "base64"

# Deploys a kamal-managed app with **Conductor's own container as the Kamal
# control machine** (Kamal is a control-machine tool; target servers are deploy
# targets that need only docker, not ruby/kamal).
#
# Flow (all local to Conductor's container):
#   1. checkout/refresh the app repo into a workspace
#   2. generate .kamal/secrets from the app's EnvVariables (Conductor = source of
#      truth for secret values — see KamalEnvWriter)
#   3. materialize the target server's SSH key so Kamal (net-ssh) can reach it
#   4. run `kamal deploy` locally — it builds via the local docker daemon and
#      SSHes to app.server.ip_address to boot the release
#
# Infra prerequisites (see docs/roadmap/plan-kamal-control-machine.html):
#   - the `kamal` gem in Conductor's bundle
#   - docker CLI in the image + the host's /var/run/docker.sock mounted in
#   - the app repo reachable (public, or a deploy key/token — separate backlog item)
class KamalDeployer
  attr_reader :app, :deployment, :error

  def initialize(app, deployment, shell: nil)
    @app = app
    @deployment = deployment
    @shell = shell || LocalShell.new
  end

  def deploy!
    deployment.start!
    log "Deploying #{app.name} via Kamal (control machine: Conductor)"

    return fail_with("App has no repository_url") if app.repository_url.blank?
    return fail_with("App has no target host") if app.server&.ip_address.blank?

    deployment.mark_deploying!
    FileUtils.mkdir_p(workspace)
    @key_file = write_ssh_key
    @deploy_key_file = write_deploy_key

    return false unless run_step("Syncing repo", sync_repo_command, env: git_env)
    write_secrets_file
    return false unless run_step("kamal deploy", kamal_command, chdir: checkout_dir, env: deploy_env)

    deployment.succeed!
    log "Kamal deployment completed successfully!"
    broadcast_status("succeeded")
    true
  rescue StandardError => e
    fail_with("Unexpected error: #{e.message}")
  ensure
    cleanup_key
  end

  private

  def run_step(label, command, chdir: nil, env: {})
    log "Running: #{label}"
    result = @shell.run(*command, chdir: chdir, env: env) { |line| log(line) }
    return true if result.success?

    fail_with("#{label} failed (exit #{result.exit_code})")
    false
  end

  # Idempotent: clone on first deploy, otherwise hard-reset to the branch's head.
  def sync_repo_command
    branch = app.branch.presence || "main"
    script = if Dir.exist?(File.join(checkout_dir, ".git"))
      "cd #{esc(checkout_dir)} && git fetch origin && git checkout #{esc(branch)} && git reset --hard origin/#{esc(branch)}"
    else
      "git clone --branch #{esc(branch)} #{esc(repo_url)} #{esc(checkout_dir)}"
    end
    ["bash", "-lc", script]
  end

  # Use the SSH form of the repo URL when a deploy key is present, so the private
  # key (a read-only GitHub deploy key) authenticates the clone of a private repo.
  def repo_url
    app.deploy_key ? DeployKey.ssh_url(app.repository_url) : app.repository_url
  end

  # Git env pointing git at the materialized deploy key (if any).
  def git_env
    return {} unless @deploy_key_file

    { "GIT_SSH_COMMAND" => "ssh -i #{@deploy_key_file} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" }
  end

  # Materialize the repo deploy key (separate from the target-host ssh key).
  def write_deploy_key
    key = app.deploy_key&.private_key
    return nil if key.blank?

    path = File.join(workspace, ".deploykey_#{app.slug}")
    File.write(path, key.end_with?("\n") ? key : "#{key}\n")
    File.chmod(0o600, path)
    path
  end

  # `kamal deploy` from the checkout; prefer the bundled binstub.
  def kamal_command
    kamal = File.exist?(File.join(checkout_dir, "bin", "kamal")) ? "./bin/kamal" : "kamal"
    ["bash", "-lc", "#{kamal} deploy"]
  end

  # Conductor's env vars become Kamal's process env (deploy.yml ERB reads e.g.
  # DEPLOY_SERVER_IP / KAMAL_REGISTRY_USERNAME), plus the SSH key for net-ssh.
  def deploy_env
    env = app.env_variables.each_with_object({}) { |v, h| h[v.key] = v.value }
    env["DEPLOY_SERVER_IP"] ||= app.server.ip_address
    env["DEPLOY_SSH_USER"]  ||= app.server.ssh_user_or_default
    env["APP_HOST"]         ||= app.domain if app.domain.present?
    env["SSH_KEYS"] = @key_file if @key_file # consumed by deploy.yml ssh.keys
    env
  end

  # Write Conductor-managed .kamal/secrets (values from EnvVariables).
  def write_secrets_file
    content = KamalEnvWriter.secrets_content(app)
    return if content.strip.empty?

    FileUtils.mkdir_p(File.join(checkout_dir, ".kamal"))
    File.write(File.join(checkout_dir, ".kamal", "secrets"), content)
  end

  # Materialize the target server's private key so Kamal's net-ssh can use it.
  def write_ssh_key
    key = app.server.ssh_key&.private_key
    return nil if key.blank?

    path = File.join(workspace, ".ssh_#{app.slug}")
    File.write(path, key.end_with?("\n") ? key : "#{key}\n")
    File.chmod(0o600, path)
    path
  end

  def cleanup_key
    [@key_file, @deploy_key_file].compact.each do |f|
      File.delete(f) if File.exist?(f)
    end
  rescue StandardError
    nil
  end

  def checkout_dir = File.join(workspace, app.slug)

  def workspace
    ENV.fetch("KAMAL_WORKSPACE", Rails.root.join("tmp", "kamal").to_s)
  end

  def esc(value) = Shellwords.escape(value.to_s)

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
