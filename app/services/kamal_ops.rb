require "shellwords"
require "fileutils"
require "tmpdir"

# Kamal as the OPS harness, not just a deploy driver (ADR 0003/0004).
#
# The edge is an independent axis: a host-Caddy app publishes a fixed port and
# never boots kamal-proxy, and that must NOT disable `kamal app logs / exec /
# details`. Those verbs know the app's roles, its destination overlay and which
# release is current — reaching for raw `docker logs` throws all of that away and
# leaves Conductor guessing at container names, which is how an ops read ends up
# tailing a `_replaced_` leftover instead of the live release.
#
# So: whenever the app carries a real kamal config, ops go through kamal. Callers
# ask #available? and fall back only when it says no — and report which path they
# used, because "these are the logs" means something different in each case.
#
# The live-app harness. Its app commands never deploy, boot, start, stop, or
# create a container; commands inside the live app always use `app exec --reuse`.
# Edge mutations are exposed only to EdgeOperations, and deploy/rollback belong
# to KamalDeployer's explicit transaction boundary.
class KamalOps
  Result = Struct.new(:ok, :output, :via, :error, keyword_init: true) do
    def ok? = ok
  end

  DEFAULT_TAIL = 200
  MAX_TAIL = 2000

  def initialize(app, shell: nil, target_server: nil)
    @app = app
    @shell = shell || LocalShell.new
    @target_server = target_server
  end

  # "Can kamal actually answer right now?" — not merely "does a file exist". The
  # edge type is deliberately NOT consulted: a disabled proxy is still a kamal app.
  #
  # This distinction is the whole point. An externally-driven app's config
  # deliberately points
  # its hosts at `<app>-does-not-deploy-via-kamal.invalid` (RFC 2606, can never
  # resolve) so `kamal deploy` is impossible. But nuking the HOSTS breaks every
  # kamal verb, not just deploy — so an agent that ran `kamal app logs`, watched it
  # die at DNS, and concluded "kamal cannot be used for this app" was misled by our
  # own configuration rather than by kamal. Answer honestly, and say why.
  def available? = unavailable_reason.nil?

  # nil when kamal can answer; otherwise a sentence a reader can act on.
  def unavailable_reason
    return "#{@app.name} does not deploy via kamal (deploy_method: #{@app.deploy_method})" unless @app.kamal?
    if @app.self_describing? && !File.exist?(deploy_config_path)
      materialize_ops_config
      return "#{@app.name} Kamal config could not be materialized: #{@materialize_error}" if @materialize_error
    end
    return "#{@app.name} has no kamal config checked out at #{deploy_config_path}" unless File.exist?(deploy_config_path)

    nil
  end

  def logs(tail: DEFAULT_TAIL)
    run(gateway.logs(lines: bounded(tail)))
  end

  # A command in the live release, through kamal rather than a hand-built
  # `docker exec` against a container name we guessed.
  def exec(command)
    run(gateway.exec_live(command))
  end

  # The interactive form is exposed for callers that can attach a TTY. Keeping
  # it here ensures Rails console uses the same destination, secrets, and live
  # release selection as logs and exec.
  def console
    run(gateway.exec_live("bin/rails console", interactive: true))
  end

  def details
    run(gateway.details)
  end

  private

  def run(verb)
    return unavailable unless available?

    ssh_home, key_file = prepare_ssh_home
    write_secrets_file
    result = @shell.run("bash", "-lc", "#{kamal_bin} #{verb}",
                        chdir: checkout_dir, env: ops_env(key_file, ssh_home))

    Result.new(ok: result.success?, output: result.output.to_s, via: "kamal",
               error: result.success? ? nil : "kamal #{verb} failed (exit #{result.exit_code})")
  ensure
    # Never leave a private key or SSH config on disk after an ops read.
    FileUtils.remove_entry(ssh_home) if ssh_home && Dir.exist?(ssh_home)
  end

  def unavailable
    Result.new(ok: false, output: "", via: nil, error: unavailable_reason)
  end

  def ops_env(key_file, ssh_home)
    env = @app.env_variables.each_with_object({}) { |v, h| h[v.key] = v.value }
    env["DEPLOY_SERVER_IP"] ||= server&.ip_address
    env["DEPLOY_SSH_USER"]  ||= server&.ssh_user_or_default
    env["APP_HOST"]         ||= @app.domain if @app.domain.present?
    env["SSH_KEYS"] = key_file if key_file # consumed by deploy.yml ssh.keys
    env["HOME"] = ssh_home if ssh_home # Net::SSH reads the target IdentityFile from here
    env.compact
  end

  def prepare_ssh_home
    key = server&.ssh_key&.private_key
    return [ nil, nil ] if key.blank?

    FileUtils.mkdir_p(workspace)
    home = Dir.mktmpdir("kamal-ops-#{@app.slug}-", workspace)
    ssh_dir = File.join(home, ".ssh")
    FileUtils.mkdir_p(ssh_dir)
    File.chmod(0o700, ssh_dir)

    identity = File.join(ssh_dir, "identity")
    File.write(identity, key.end_with?("\n") ? key : "#{key}\n")
    File.chmod(0o600, identity)

    known_hosts = File.join(ssh_dir, "known_hosts")
    File.write(known_hosts, "")
    File.chmod(0o600, known_hosts)

    config = <<~CFG
      Host #{server.ip_address}
        User #{server.ssh_user_or_default}
        IdentityFile #{identity}
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
        UserKnownHostsFile #{known_hosts}
    CFG
    config_path = File.join(ssh_dir, "config")
    File.write(config_path, config)
    File.chmod(0o600, config_path)

    [ home, identity ]
  end

  # Kamal resolves secret references from the checkout, so an ops verb needs the
  # same file a deploy writes — otherwise `app exec` dies resolving a secret.
  def write_secrets_file
    path = File.join(checkout_dir, ".kamal", "secrets")
    content = KamalEnvWriter.secrets_content(@app, server: server)
    return if content.to_s.strip.empty?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # The deploy workspace lives inside Conductor's replaceable container. A
  # control-plane redeploy therefore removes app checkouts, but self-describing
  # apps already carry every coordinate Conductor needs to reconstruct the Kamal
  # ops harness. Materialize a minimal destination-required base plus the same
  # generated overlay/secrets used by deploy; no source clone or new app
  # container is needed for logs/details/exec --reuse.
  def materialize_ops_config
    FileUtils.mkdir_p(File.dirname(deploy_config_path))
    unless File.exist?(deploy_config_path)
      File.write(deploy_config_path, <<~YAML)
        require_destination: true
        builder:
          arch: amd64
      YAML
    end
    KamalConfig.new(@app, target_server: @target_server).files.each do |relative_path, content|
      path = File.join(checkout_dir, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    @materialize_error = nil
  rescue StandardError => e
    @materialize_error = e.message
  end

  def server = @target_server || @app.server
  def deploy_config_path = File.join(checkout_dir, "config", "deploy.yml")
  def checkout_dir = File.join(workspace, @app.slug)
  def workspace = ENV.fetch("KAMAL_WORKSPACE", Rails.root.join("tmp", "kamal").to_s)
  def kamal_bin = "BUNDLE_GEMFILE=#{Shellwords.escape(conductor_gemfile)} bundle exec kamal"
  def conductor_gemfile = ENV["CONDUCTOR_GEMFILE"].presence || Rails.root.join("Gemfile").to_s
  def bounded(tail) = [ [ tail.to_i, 1 ].max, MAX_TAIL ].min
  def gateway = @gateway ||= KamalGateway.new(destination: destination_name)
  def destination_name = @app.self_describing? ? KamalConfig::DESTINATION : nil
end
