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
    @clone_token = resolve_clone_token
    @askpass_file = @clone_token ? write_askpass(@clone_token) : nil
    @ssh_home = setup_ssh_home

    return false unless run_step("Syncing repo", sync_repo_command, env: git_env)
    record_commit_sha
    write_secrets_file
    log_ssh_diagnostics
    note_self_deploy if app.self_managed?
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

  # Record the checked-out HEAD as the deployment's commit. Kamal uses this same
  # sha as the release version (injected into the container as KAMAL_VERSION), so
  # recording it lets SelfDeployReconciler match a stranded self-deploy to the
  # release that actually booted.
  def record_commit_sha
    result = @shell.run("git", "-C", checkout_dir, "rev-parse", "HEAD")
    sha = result.output.to_s.strip
    deployment.update!(commit_sha: sha) if result.success? && sha.present?
  rescue StandardError
    nil
  end

  # A self-managed deploy replaces THIS Conductor container, killing this job
  # mid-`kamal deploy`. Explain that in the log so a truncated deploy log isn't
  # mistaken for a crash; the new release reconciles the status on boot.
  def note_self_deploy
    log "Self-managed deploy: kamal will replace this Conductor container. If this " \
        "job is terminated during the release swap, the deployment is reconciled " \
        "when the new release boots (commit #{deployment.commit_sha.to_s[0, 12]})."
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

  # Clone auth precedence: GitHub App installation token (https) → deploy key
  # (ssh) → plain url.
  def repo_url
    if @clone_token && app.github_repo
      "https://x-access-token@github.com/#{app.github_repo}.git"
    elsif app.deploy_key
      DeployKey.ssh_url(app.repository_url)
    else
      app.repository_url
    end
  end

  def git_env
    if @askpass_file
      { "GIT_ASKPASS" => @askpass_file, "GIT_TERMINAL_PROMPT" => "0" }
    elsif @deploy_key_file
      { "GIT_SSH_COMMAND" => "ssh -i #{@deploy_key_file} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" }
    else
      {}
    end
  end

  # A short-lived GitHub App installation token for cloning, or nil.
  def resolve_clone_token
    return nil unless app.github_repo

    gh = GithubApp.from_config
    return nil unless gh

    gh.clone_token_for(app.github_repo)
  rescue GithubApp::Error => e
    log "GitHub App token unavailable (#{e.message}); falling back to deploy key / plain url"
    nil
  end

  # Askpass script feeds the token as the git password (never in a logged command).
  def write_askpass(token)
    path = File.join(workspace, ".askpass_#{app.slug}")
    File.write(path, "#!/bin/sh\nexec echo #{Shellwords.escape(token)}\n")
    File.chmod(0o700, path)
    path
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
    if @ssh_home
      # Build on the target's docker daemon over SSH (avoids mounting docker.sock
      # into this container). The host key + identity live in the real ~/.ssh that
      # docker's ssh connhelper reads — NOT an env $HOME, which ssh ignores (it
      # resolves ~ from the passwd database, not $HOME).
      env["DOCKER_HOST"] = "ssh://#{app.server.ssh_user_or_default}@#{app.server.ip_address}"
    end
    env
  end

  # The ssh dir that OpenSSH actually reads. ssh resolves `~` from the passwd
  # database (getpwuid), ignoring $HOME, so we must write into the real home —
  # not an isolated one. Overridable in tests so they never touch the real ~/.ssh.
  def ssh_dir
    File.join(ENV.fetch("CONDUCTOR_SSH_HOME") { Dir.home }, ".ssh")
  end

  # Prepare the real ~/.ssh so `docker --host ssh://…` (buildx, over SSH) and
  # `kamal` (net-ssh) can both reach the target: a per-app identity key, a Host
  # stanza pointing at it, and the pre-trusted host key. Returns the dir.
  def setup_ssh_home
    return nil unless @key_file

    ssh = ssh_dir
    FileUtils.mkdir_p(ssh)
    File.chmod(0o700, ssh)

    @managed_identity = File.join(ssh, "conductor_#{app.slug}")
    FileUtils.cp(@key_file, @managed_identity)
    File.chmod(0o600, @managed_identity)

    known_hosts = File.join(ssh, "known_hosts")
    write_ssh_config_block(File.join(ssh, "config"), @managed_identity, known_hosts)
    seed_known_hosts(known_hosts)
    ssh
  end

  # Idempotently upsert a marked Host stanza in ~/.ssh/config for this app's
  # target, so repeat deploys don't accumulate duplicate blocks.
  def write_ssh_config_block(config_path, identity, known_hosts)
    b = "# >>> conductor #{app.slug} >>>"
    e = "# <<< conductor #{app.slug} <<<"
    block = <<~CFG
      #{b}
      Host #{app.server.ip_address}
        User #{app.server.ssh_user_or_default}
        IdentityFile #{identity}
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
        UserKnownHostsFile #{known_hosts}
      #{e}
    CFG
    existing = File.exist?(config_path) ? File.read(config_path) : ""
    existing = existing.gsub(/#{Regexp.escape(b)}.*?#{Regexp.escape(e)}\n/m, "")
    File.write(config_path, existing + block)
    File.chmod(0o600, config_path)
  end

  # Pre-trust the target's SSH host key. The build runs on the target's docker
  # daemon over SSH (DOCKER_HOST=ssh://…), and docker's buildx connection — like
  # Kamal's net-ssh — verifies the host key but does NOT honor `accept-new` on
  # first contact, so a first-ever deploy dies with "Host key verification failed".
  # Seed it into the real ~/.ssh/known_hosts (skip if already trusted).
  def seed_known_hosts(path)
    ip = app.server.ip_address
    @shell.run("bash", "-lc",
      "touch #{esc(path)}; ssh-keygen -F #{esc(ip)} -f #{esc(path)} >/dev/null 2>&1 || " \
      "ssh-keyscan -t rsa,ecdsa,ed25519 #{esc(ip)} 2>/dev/null >> #{esc(path)}; true")
  end

  # Diagnostics for the build-over-SSH host-key path. The build runs on the
  # target daemon via DOCKER_HOST=ssh://… and buildx's connection must trust the
  # host key. This probes the EXACT connection (same env as `kamal deploy`) so a
  # failure here localizes the problem to the docker-over-ssh handshake rather
  # than buildx internals. Never fails the deploy.
  def log_ssh_diagnostics
    return unless @ssh_home

    user = esc(app.server.ssh_user_or_default)
    host = esc(app.server.ip_address)
    script = <<~SH
      echo "ssh probe:"; ssh -o BatchMode=yes -o ConnectTimeout=8 #{user}@#{host} 'echo ssh-ok' 2>&1 | tail -2
      echo "docker-over-ssh probe:"; docker version --format 'server={{.Server.Version}}' 2>&1 | tail -2
    SH
    log "Running: SSH/Docker diagnostics"
    @shell.run("bash", "-lc", script, env: deploy_env) { |line| log(line) }
  rescue StandardError => e
    log "diagnostics error: #{e.message}"
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

  # Remove the materialized secrets. @ssh_home is the real ~/.ssh — never delete
  # it; only the per-app identity key we copied in. The known_hosts/config block
  # are left in place (host trust persists; the block is re-upserted next deploy).
  def cleanup_key
    [@key_file, @deploy_key_file, @askpass_file, @managed_identity].compact.each do |f|
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
