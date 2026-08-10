require "test_helper"
require "tmpdir"

# Kamal is the OPS harness, not just a deploy driver (ADR 0003/0004). The edge can
# be off — a host-Caddy app publishes a fixed port and never boots kamal-proxy —
# and `kamal app logs / exec / details` must still be the path Conductor uses when
# the app carries a kamal config. Reaching for raw `docker logs` instead throws
# away release awareness, the destination overlay, and the roles kamal knows about.
class KamalOpsTest < ActiveSupport::TestCase
  class FakeShell
    attr_reader :runs
    def initialize(output: "", success: true) = (@output = output; @success = success; @runs = [])

    def run(*command, chdir: nil, env: {})
      @runs << { command: command, chdir: chdir, env: env }
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

  test "the SSH key is materialized so kamal can reach the box, and removed after" do
    write_deploy_config
    shell = FakeShell.new
    ops = KamalOps.new(@app, shell: shell)

    ops.logs
    key_path = shell.runs.last[:env]["SSH_KEYS"]

    assert key_path.present?, "kamal needs an explicit key; env was #{shell.runs.last[:env].keys.inspect}"
    refute File.exist?(key_path), "the materialized key must not be left on disk"
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
end
