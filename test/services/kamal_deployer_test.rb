require "test_helper"

class KamalDeployerTest < ActiveSupport::TestCase
  # Captures the streamed script and reports success/failure like SshConnection.
  class FakeSsh
    attr_reader :scripts

    def initialize(success: true, exit_code: 0)
      @success = success
      @exit_code = exit_code
      @scripts = []
    end

    def execute_stream(script, &_block)
      @scripts << script
      { success: @success, exit_code: @exit_code }
    end
  end

  setup do
    user = User.create!(email: "deployer@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9", ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "kuickr", slug: "kuickr", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git", branch: "main")
    @app.env_variables.create!(key: "APP_HOST", value: "kuickr.co")
    @deployment = @app.deployments.create!(user: user)
  end

  def deploy_with(ssh)
    deployer = KamalDeployer.new(@app, @deployment)
    deployer.instance_variable_set(:@ssh, ssh)
    deployer.deploy!
    deployer
  end

  test "runs git sync + kamal deploy over SSH and marks the deployment succeeded" do
    ssh = FakeSsh.new(success: true)
    deploy_with(ssh)

    script = ssh.scripts.first
    assert_includes script, "git clone 'https://github.com/pavelabs/kuickr.git'"
    assert_includes script, "git reset --hard origin/'main'"
    assert_includes script, "cd '#{@app.app_dir}'"
    assert_includes script, "export APP_HOST='kuickr.co'"
    assert_includes script, "$KAMAL deploy"
    assert_includes script, "bin/kamal"
    assert_equal "succeeded", @deployment.reload.status
  end

  test "writes .kamal/secrets from the app's env vars (Conductor as source of truth)" do
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "skb_xyz")
    ssh = FakeSsh.new(success: true)
    deploy_with(ssh)

    script = ssh.scripts.first
    assert_includes script, "> .kamal/secrets"
    # The secrets content is base64-encoded into the script; decode and check it.
    encoded = script[/echo '([A-Za-z0-9+\/=]+)' \| base64 --decode > \.kamal\/secrets/, 1]
    assert encoded, "expected a base64 secrets blob in the script"
    decoded = Base64.decode64(encoded)
    assert_includes decoded, "SECRET_KEY_BASE=skb_xyz"
    assert_includes decoded, "APP_HOST=kuickr.co"
  end

  test "marks the deployment failed when kamal deploy exits nonzero" do
    deploy_with(FakeSsh.new(success: false, exit_code: 1))

    assert_equal "failed", @deployment.reload.status
  end

  test "fails fast when the server has no SSH configured" do
    @server.update!(ssh_key: nil)
    deployer = deploy_with(FakeSsh.new)

    assert_equal "failed", @deployment.reload.status
    assert_match "SSH not configured", deployer.error
  end
end
