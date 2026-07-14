require "test_helper"

# Covers the MCP server tools added for adopting existing hosts: update (attach
# an SSH key / set the login user) and test_connection (verify + refresh).
class ServerUpdateToolsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "mcp-admin@example.com", admin: true)
    @org  = Organization.create_for(@user, name: "Acme")
    @server = @org.servers.create!(name: "ssd-node", ip_address: "89.233.107.200", status: "offline", ssh_user: "deploy")
    @key = @org.ssh_keys.create!(name: "conductor-ssd", private_key: valid_private_key)
  end

  # --- update ------------------------------------------------------------

  test "update attaches an SSH key by id and sets the login user" do
    result = UpdateServerTool.new(user: @user).call(
      "server_id" => @server.id, "ssh_key_id" => @key.id, "ssh_user" => "root", "ssh_port" => 22
    )
    assert result.success?, result.error
    @server.reload
    assert_equal @key, @server.ssh_key
    assert_equal "root", @server.ssh_user
    assert_includes result.value[:message], "test_connection"
  end

  test "update attaches an SSH key by name" do
    result = UpdateServerTool.new(user: @user).call(
      "server_name" => "ssd-node", "ssh_key_name" => "conductor-ssd"
    )
    assert result.success?, result.error
    assert_equal @key, @server.reload.ssh_key
  end

  test "update reports available keys when the name is unknown" do
    result = UpdateServerTool.new(user: @user).call("server_id" => @server.id, "ssh_key_name" => "nope")
    assert result.failure?
    assert_includes result.error, "conductor-ssd"
  end

  test "update fails on unknown server" do
    result = UpdateServerTool.new(user: @user).call("server_id" => 0, "ssh_user" => "root")
    assert result.failure?
  end

  test "update requires at least one field" do
    result = UpdateServerTool.new(user: @user).call("server_id" => @server.id)
    assert result.failure?
    assert_includes result.error, "Nothing to update"
  end

  # --- add_ssh_key -------------------------------------------------------

  test "add_ssh_key generates a key server-side and returns only the public half" do
    assert_difference -> { @org.ssh_keys.count }, 1 do
      @result = GenerateSshKeyTool.new(user: @user).call("name" => "Fleet key")
    end
    assert @result.success?, @result.error
    assert @result.value[:public_key].to_s.start_with?("ssh-ed25519 ")
    refute @result.value.key?(:private_key), "the private key must never be returned"

    key = SshKey.find(@result.value[:id])
    assert key.private_key.present?, "private key is stored (encrypted) in Conductor"
  end

  # --- test_connection ---------------------------------------------------

  test "test_connection reports failure without touching metrics" do
    SshConnection.stub(:new, ->(_s) { FakeSsh.new(ok: false, error: "Authentication failed") }) do
      result = TestServerConnectionTool.new(user: @user).call("server_id" => @server.id)
      assert result.success?, result.error
      assert_equal false, result.value[:connected]
      assert_includes result.value[:error], "Authentication failed"
    end
  end

  test "test_connection refreshes metrics on success" do
    refreshed = false
    SshConnection.stub(:new, ->(_s) { FakeSsh.new(ok: true) }) do
      ServerMetrics.stub(:new, ->(s) { FakeMetrics.new(s) { refreshed = true } }) do
        result = TestServerConnectionTool.new(user: @user).call("server_id" => @server.id)
        assert result.success?, result.error
        assert_equal true, result.value[:connected]
      end
    end
    assert refreshed, "metrics should be refreshed on a successful connection"
  end

  # --- audit / apply_updates / install_packages --------------------------

  AuditCheck  = Struct.new(:label, :status, :detail, keyword_init: true)
  AuditResult = Struct.new(:status, :checks, :error, keyword_init: true) do
    def ok? = error.nil?
  end

  test "audit returns the graded security posture" do
    fake_audit = Object.new
    fake_audit.define_singleton_method(:audit) do
      AuditResult.new(status: :secure, checks: [ AuditCheck.new(label: "Firewall (ufw)", status: :ok, detail: "active") ], error: nil)
    end
    ServerAudit.stub(:new, ->(*) { fake_audit }) do
      result = ServerAuditTool.new(user: @user).call("server_id" => @server.id)
      assert result.success?, result.error
      assert_equal :secure, result.value[:status]
      assert_equal "Firewall (ufw)", result.value[:checks].first[:check]
    end
  end

  test "apply_updates marks the server updating and defaults to security scope" do
    result = ApplyServerUpdatesTool.new(user: @user).call("server_id" => @server.id)
    assert result.success?, result.error
    assert_equal "security", result.value[:scope]
    assert_equal "running", @server.reload.last_update_status
  end

  test "apply_updates accepts scope=all" do
    result = ApplyServerUpdatesTool.new(user: @user).call("server_id" => @server.id, "scope" => "all")
    assert_equal "all", result.value[:scope]
  end

  test "install_packages requires package names" do
    result = InstallServerPackagesTool.new(user: @user).call("server_id" => @server.id, "packages" => "")
    assert result.failure?
  end

  test "install_packages records the packages and marks the install running" do
    result = InstallServerPackagesTool.new(user: @user).call("server_id" => @server.id, "packages" => "htop ncdu")
    assert result.success?, result.error
    assert_includes result.value[:packages], "htop"
    assert_equal "running", @server.reload.last_package_install_status
  end

  # --- scoping -----------------------------------------------------------

  test "a non-admin actor cannot update a server outside their orgs" do
    outsider = User.create!(email: "outsider@example.com")
    outsider.ensure_personal_organization!
    Current.organization = outsider.organizations.first
    result = UpdateServerTool.new(user: outsider).call("server_id" => @server.id, "ssh_user" => "root")
    assert result.failure?
  ensure
    Current.organization = nil
  end

  private

  class FakeSsh
    def initialize(ok:, error: nil) = (@ok, @error = ok, error)
    def test = @ok
    def error = @error
  end

  class FakeMetrics
    def initialize(server, &blk) = (@server, @blk = server, blk)
    def fetch_and_update!
      @server.update!(last_seen_at: Time.current, status: "online")
      @blk&.call
      true
    end
  end
end
