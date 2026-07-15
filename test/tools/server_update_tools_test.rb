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

  test "test_connection reports a failed probe as an error (isError), not a success" do
    SshConnection.stub(:new, ->(_s) { FakeSsh.new(ok: false, error: "Authentication failed") }) do
      result = TestServerConnectionTool.new(user: @user).call("server_id" => @server.id)
      assert result.failure?, "a broken connection must be a failure, not a logged success"
      assert_includes result.error, "Authentication failed"
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

  test "update rejects an ssh_key_id belonging to another organization (IDOR)" do
    other = Organization.create_for(User.create!(email: "o2@example.com"), name: "Other Co")
    other_key = other.ssh_keys.create!(name: "theirs", private_key: valid_private_key)
    Current.organization = @org
    Current.org_scoped = true
    result = UpdateServerTool.new(user: @user).call("server_id" => @server.id, "ssh_key_id" => other_key.id)
    assert result.failure?, "must not attach another org's key by raw id"
    assert_nil @server.reload.ssh_key_id
  ensure
    Current.organization = nil
    Current.org_scoped = nil
  end

  test "an org-scoped admin token cannot CREATE resources in another org" do
    other = Organization.create_for(User.create!(email: "o4@example.com"), name: "Other Co")
    Current.organization = @org
    Current.org_scoped = true
    result = RegisterServerTool.new(user: @user).call(
      "name" => "sneaky-box", "ip_address" => "1.2.3.4", "ssh_user" => "root", "organization_id" => other.id
    )
    assert result.failure?, "org-bound token must not create in another org, even as admin"
    assert_equal 0, other.servers.count
  ensure
    Current.organization = nil
    Current.org_scoped = nil
  end

  test "an org-scoped admin token cannot see servers outside its org" do
    other = Organization.create_for(User.create!(email: "o3@example.com"), name: "Other Co")
    other_server = other.servers.create!(name: "theirs-box", status: "offline")
    Current.organization = @org
    Current.org_scoped = true
    result = UpdateServerTool.new(user: @user).call("server_id" => other_server.id, "ssh_user" => "root")
    assert result.failure?, "org-bound token must not reach another org's server even as admin"
  ensure
    Current.organization = nil
    Current.org_scoped = nil
  end

  test "a plain member's token cannot run a mutating tool (operator gate)" do
    member = User.create!(email: "toolmember@example.com")
    @org.add_member(member, role: :member)
    Current.organization = @org
    Current.org_scoped = true
    result = ToolRegistry.call("conductor_server",
      { "action" => "run_script", "server_id" => @server.id, "script_name" => "server-provision" }, user: member)
    assert result.failure?, "a non-owner must not execute infrastructure via MCP"
    assert_includes result.error, "owner"
  ensure
    Current.organization = nil
    Current.org_scoped = nil
  end

  test "a non-admin org owner CAN run mutating tools (the gate lets owners through)" do
    owner = User.create!(email: "plainowner@example.com")
    org = Organization.create_for(owner, name: "Owned Co") # owner is the org owner, not a platform admin
    server = org.servers.create!(name: "ownbox", status: "online", ip_address: "10.1.1.1")
    Current.organization = org
    Current.org_scoped = true
    result = ToolRegistry.call("conductor_server", { "action" => "audit", "server_id" => server.id }, user: owner)
    # audit may fail on SSH, but it must NOT be blocked by the owner gate.
    refute_includes result.error.to_s, "requires an organization owner"
  ensure
    Current.organization = nil
    Current.org_scoped = nil
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
