require "test_helper"
require "tmpdir"

class KamalDeployerTest < ActiveSupport::TestCase
  # Records local commands and returns a canned result.
  class FakeShell
    attr_reader :runs
    def initialize(success: true)
      @success = success
      @runs = []
    end

    def run(*command, chdir: nil, env: {})
      @runs << { command: command, chdir: chdir, env: env }
      yield "…output…" if block_given?
      LocalShell::Result.new(success: @success, exit_code: @success ? 0 : 1, output: "out")
    end
  end

  setup do
    @workspace = Dir.mktmpdir("kamal-test")
    ENV["KAMAL_WORKSPACE"] = @workspace
    user = User.create!(email: "kd@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9", ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git", branch: "main", domain: "kuickr.co")
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "skb_xyz")
    @deployment = @app.deployments.create!(user: user)
  end

  teardown do
    ENV.delete("KAMAL_WORKSPACE")
    FileUtils.remove_entry(@workspace) if @workspace && Dir.exist?(@workspace)
  end

  def deploy_with(shell)
    KamalDeployer.new(@app, @deployment, shell: shell).tap(&:deploy!)
  end

  test "runs git sync then kamal deploy locally, marks deployment succeeded" do
    shell = FakeShell.new(success: true)
    deploy_with(shell)

    cmds = shell.runs.map { |r| r[:command].last }
    assert cmds.any? { |c| c.include?("git clone") && c.include?("kuickr.git") }, "expected a git clone step"
    kamal_run = shell.runs.find { |r| r[:command].last.include?("kamal deploy") }
    assert kamal_run, "expected a kamal deploy step"
    assert_equal File.join(@workspace, "kuickr"), kamal_run[:chdir]
    assert_equal "succeeded", @deployment.reload.status
  end

  test "generates .kamal/secrets from the app's env vars (Conductor = source of truth)" do
    deploy_with(FakeShell.new(success: true))

    secrets = File.read(File.join(@workspace, "kuickr", ".kamal", "secrets"))
    assert_includes secrets, "SECRET_KEY_BASE=skb_xyz"
  end

  test "passes Conductor's env (incl. deploy host) to the kamal subprocess" do
    shell = FakeShell.new(success: true)
    deploy_with(shell)

    env = shell.runs.find { |r| r[:command].last.include?("kamal deploy") }[:env]
    assert_equal "skb_xyz", env["SECRET_KEY_BASE"]
    assert_equal "10.0.0.9", env["DEPLOY_SERVER_IP"]
    assert_equal "deploy", env["DEPLOY_SSH_USER"]
    assert env["SSH_KEYS"].present?, "expected the materialized ssh key path"
  end

  test "materializes and then cleans up the target ssh key" do
    captured = nil
    shell = FakeShell.new(success: true)
    # capture the key path the deployer used
    deployer = KamalDeployer.new(@app, @deployment, shell: shell)
    deployer.deploy!
    key_path = shell.runs.last[:env]["SSH_KEYS"]
    refute File.exist?(key_path), "ssh key file should be cleaned up after deploy"
  end

  test "marks the deployment failed when kamal deploy exits nonzero" do
    deploy_with(FakeShell.new(success: false))
    assert_equal "failed", @deployment.reload.status
  end

  test "fails fast when the app has no target host" do
    @server.update!(ip_address: nil)
    deployer = KamalDeployer.new(@app, @deployment, shell: FakeShell.new)
    deployer.deploy!
    assert_equal "failed", @deployment.reload.status
    assert_match "target host", deployer.error
  end
end
