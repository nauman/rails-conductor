require "test_helper"
require "tmpdir"

# Kamal is the OPS harness, not just a deploy driver (ADR 0003/0004). The edge can
# be off — a host-Caddy app publishes a fixed port and never boots kamal-proxy —
# and `kamal app logs / exec / details` must still be the path Conductor uses when
# the app carries a kamal config. Reaching for raw `docker logs` instead throws
# away release awareness, the destination overlay, and the roles kamal knows about.
class KamalOpsTest < ActiveSupport::TestCase
  class FakeShell
    attr_reader :runs, :ssh_config_at_run, :identity_present_at_run
    def initialize(output: "", success: true) = (@output = output; @success = success; @runs = [])

    def run(*command, chdir: nil, env: {})
      @runs << { command: command, chdir: chdir, env: env }
      config_path = File.join(env["HOME"].to_s, ".ssh", "config")
      if File.exist?(config_path)
        @ssh_config_at_run = File.read(config_path)
        identity = @ssh_config_at_run[/IdentityFile (\S+)/, 1]
        @identity_present_at_run = identity.present? && File.exist?(identity)
      end
      yield @output if block_given?
      LocalShell::Result.new(success: @success, exit_code: @success ? 0 : 1, output: @output)
    end
  end

  setup do
    @workspace = Dir.mktmpdir("kamal-ops")
    ENV["KAMAL_WORKSPACE"] = @workspace
    user = User.create!(email: "ops@example.com")
    @org = Organization.create_for(user, name: "Ops Co")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.9",
                                   ssh_key: @key, ssh_user: "deploy", edge_type: "caddy")
    @app = @org.apps.create!(name: "Opsy", slug: "opsy", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "opsy.test")
  end

  teardown do
    FileUtils.remove_entry(@workspace) if @workspace && File.exist?(@workspace)
    ENV.delete("KAMAL_WORKSPACE")
  end

  def write_deploy_config(body = "service: opsy\n")
    dir = File.join(@workspace, @app.slug, "config")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "deploy.yml"), body)
  end

  test "unavailable when the app has no kamal config checked out" do
    refute KamalOps.new(@app, shell: FakeShell.new).available?,
      "without a config/deploy.yml there is nothing for kamal to read"
  end

  test "unavailable for a non-kamal app even if a config happens to exist" do
    write_deploy_config
    @app.update!(deploy_method: "docker")

    refute KamalOps.new(@app, shell: FakeShell.new).available?
  end

  test "available once a kamal app has its config, even with the edge disabled" do
    write_deploy_config
    assert_equal "caddy", @server.edge_type, "this app runs proxy-less on purpose"

    assert KamalOps.new(@app, shell: FakeShell.new).available?,
      "a disabled edge must not disable the ops harness"
  end

  test "a self-describing app rebuilds its ops-only Kamal config after the control container restarts" do
    @app.update!(self_describing: true, port: 9080)
    @app.env_variables.create!(key: "KAMAL_REGISTRY_USERNAME", value: "owner")
    @app.env_variables.create!(key: "KAMAL_REGISTRY_PASSWORD", value: "token", secret: true)
    @app.deployments.create!(user: @org.users.first, server: @server, status: "succeeded",
                             commit_sha: "abc123", release_version: "abc123", deploy_method: "kamal")
    shell = FakeShell.new(output: "live logs")
    ops = KamalOps.new(@app, shell: shell)

    assert ops.available?
    base_path = File.join(@workspace, @app.slug, "config", "deploy.yml")
    assert File.exist?(base_path)
    assert_equal "amd64", YAML.safe_load_file(base_path).dig("builder", "arch")
    assert File.exist?(File.join(@workspace, @app.slug, "config", "deploy.production.yml"))
    assert File.exist?(File.join(@workspace, @app.slug, ".kamal", "secrets.production"))
    assert ops.logs.ok?
    assert_match(/-d production/, shell.runs.last[:command].last)
    assert_equal "abc123", shell.runs.last[:env]["VERSION"]
  end

  test "logs run `kamal app logs` with a bounded tail, in the checkout" do
    write_deploy_config
    shell = FakeShell.new(output: "web-1 | started\n")

    result = KamalOps.new(@app, shell: shell).logs(tail: 25)

    assert result.ok?
    assert_equal "kamal", result.via
    cmd = shell.runs.last[:command].last
    assert_match(/app logs/, cmd)
    assert_match(/-n 25/, cmd)
    assert_equal File.join(@workspace, @app.slug), shell.runs.last[:chdir]
  end

  test "exec runs a command through `kamal app exec`" do
    write_deploy_config
    shell = FakeShell.new(output: "ok")

    result = KamalOps.new(@app, shell: shell).exec("bin/rails db:migrate:status")

    assert result.ok?
    cmd = shell.runs.last[:command].last
    assert_match(/app exec/, cmd)
    assert_match(/db:migrate:status/, cmd)
  end

  test "console uses the live release with Kamal's interactive reuse flags" do
    write_deploy_config
    shell = FakeShell.new(output: "console")

    result = KamalOps.new(@app, shell: shell).console

    assert result.ok?
    assert_match(/app exec --interactive --reuse/, shell.runs.last[:command].last)
    assert_match(/bin\\?\/rails\\? console/, shell.runs.last[:command].last)
  end

  test "the SSH key is materialized so kamal can reach the box, and removed after" do
    write_deploy_config
    shell = FakeShell.new
    ops = KamalOps.new(@app, shell: shell)

    ops.logs
    key_path = shell.runs.last[:env]["SSH_KEYS"]

    assert key_path.present?, "kamal needs an explicit key; env was #{shell.runs.last[:env].keys.inspect}"
    refute File.exist?(key_path), "the materialized key must not be left on disk"
  end

  test "ops pins HOME to an isolated SSH config that Net SSH can authenticate with" do
    write_deploy_config
    shell = FakeShell.new

    KamalOps.new(@app, shell: shell).logs

    assert_includes shell.ssh_config_at_run, "Host 10.0.0.9"
    assert_includes shell.ssh_config_at_run, "User deploy"
    assert shell.identity_present_at_run, "the IdentityFile must exist while Kamal runs"
    refute Dir.exist?(shell.runs.last[:env]["HOME"]), "the isolated SSH home must be removed afterwards"
  end

  test "a failing kamal command reports the failure rather than pretending to succeed" do
    write_deploy_config
    result = KamalOps.new(@app, shell: FakeShell.new(output: "boom", success: false)).logs

    refute result.ok?
    assert_match(/boom/, result.error.to_s + result.output.to_s)
  end

  test "a self-describing app targets its destination overlay" do
    write_deploy_config
    @app.update!(self_describing: true) if @app.respond_to?(:self_describing=)
    skip "app has no self_describing flag" unless @app.respond_to?(:self_describing?)

    shell = FakeShell.new
    KamalOps.new(@app, shell: shell).logs

    cmd = shell.runs.last[:command].last
    assert_match(/-d #{KamalConfig::DESTINATION}/, cmd) if @app.self_describing?
  end

  # The gap that misled an agent. InventList's config deliberately points its
  # hosts at `inventlist-does-not-deploy-via-kamal.invalid` (RFC 2606, can never
  # resolve) to make `kamal deploy` impossible. But nuking the HOSTS breaks every
  test "a config with a deploy guard still keeps the Kamal ops harness available" do
    write_deploy_config(<<~YML)
      service: opsy
      servers:
        web:
          hosts:
            - opsy-does-not-deploy-via-kamal.invalid
    YML

    ops = KamalOps.new(@app, shell: FakeShell.new)

    assert ops.available?, "deploy policy must not disable Kamal health/logs/exec"
    assert_nil ops.unavailable_reason
  end

  test "the reason distinguishes a missing config from a deploy-blocked one" do
    ops = KamalOps.new(@app, shell: FakeShell.new)

    refute ops.available?
    assert_match(/no kamal config/i, ops.unavailable_reason)
    refute_match(/\.invalid/, ops.unavailable_reason)
  end

  test "a real host keeps ops available even though the edge is off" do
    write_deploy_config(<<~YML)
      service: opsy
      proxy: false
      servers:
        web:
          hosts:
            - 89.233.107.200
    YML

    ops = KamalOps.new(@app, shell: FakeShell.new)
    assert ops.available?, "proxy: false plus a real host is the sanctioned Caddy-mode shape"
    assert_nil ops.unavailable_reason
  end

  test "an ops call still reaches Kamal when deploy policy is separate" do
    write_deploy_config("servers:\n  web:\n    hosts:\n      - x-does-not-deploy-via-kamal.invalid\n")
    shell = FakeShell.new

    result = KamalOps.new(@app, shell: shell).logs

    assert result.ok?
    assert_equal 1, shell.runs.size
  end
end
