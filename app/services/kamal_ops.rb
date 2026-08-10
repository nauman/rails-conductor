require "shellwords"
require "fileutils"

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
# Read-only by intent. This runs ops verbs; it never deploys, boots or stops.
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

  # Can kamal actually answer for this app right now? Two conditions, both real:
  # the app deploys via kamal, and its config is on disk for kamal to read. The
  # edge type is deliberately NOT consulted — a disabled proxy is still a kamal app.
  def available?
    @app.kamal? && File.exist?(deploy_config_path)
  end

  def logs(tail: DEFAULT_TAIL)
    run("app logs -n #{bounded(tail)}")
  end

  # A command in the live release, through kamal rather than a hand-built
  # `docker exec` against a container name we guessed.
  def exec(command)
    run("app exec #{Shellwords.escape(command)}")
  end

  def details
    run("app details")
  end

  private

  def run(verb)
    return unavailable unless available?

    key_file = write_ssh_key
    write_secrets_file
    result = @shell.run("bash", "-lc", "#{kamal_bin} #{verb}#{destination_flag}",
                        chdir: checkout_dir, env: ops_env(key_file))

    Result.new(ok: result.success?, output: result.output.to_s, via: "kamal",
               error: result.success? ? nil : "kamal #{verb} failed (exit #{result.exit_code})")
  ensure
    # Never leave a private key on disk after an ops read.
    FileUtils.rm_f(key_file) if key_file
  end

  def unavailable
    Result.new(ok: false, output: "", via: nil,
               error: "#{@app.name} has no kamal config checked out — kamal ops unavailable")
  end

  def ops_env(key_file)
    env = @app.env_variables.each_with_object({}) { |v, h| h[v.key] = v.value }
    env["DEPLOY_SERVER_IP"] ||= server&.ip_address
    env["DEPLOY_SSH_USER"]  ||= server&.ssh_user_or_default
    env["APP_HOST"]         ||= @app.domain if @app.domain.present?
    env["SSH_KEYS"] = key_file if key_file # consumed by deploy.yml ssh.keys
    env.compact
  end

  def write_ssh_key
    key = server&.ssh_key&.private_key
    return nil if key.blank?

    path = File.join(workspace, ".ssh_ops_#{@app.slug}")
    File.write(path, key.end_with?("\n") ? key : "#{key}\n")
    File.chmod(0o600, path)
    path
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

  def server = @target_server || @app.server
  def deploy_config_path = File.join(checkout_dir, "config", "deploy.yml")
  def checkout_dir = File.join(workspace, @app.slug)
  def workspace = ENV.fetch("KAMAL_WORKSPACE", Rails.root.join("tmp", "kamal").to_s)
  def destination_flag = @app.self_describing? ? " -d #{KamalConfig::DESTINATION}" : ""
  def kamal_bin = "BUNDLE_GEMFILE=#{Shellwords.escape(conductor_gemfile)} bundle exec kamal"
  def conductor_gemfile = ENV["CONDUCTOR_GEMFILE"].presence || Rails.root.join("Gemfile").to_s
  def bounded(tail) = [ [ tail.to_i, 1 ].max, MAX_TAIL ].min
end
