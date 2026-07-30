require "test_helper"

# conductor_app action=stop — remove an app's containers on a chosen box. Needed to
# clear a stale/orphaned container (e.g. a half-deployed transfer target holding a
# port) so a redeploy is clean, without ssh-ing by hand. Scoped by the kamal
# service label, so it only ever touches this app's own containers on that server.
class StopAppToolTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :server, :commands
    def initialize(server) = (@server = server; @commands = [])
    def execute_with_status(cmd) = (@commands << cmd; { success: true, stdout: "abc123\ndef456\n", stderr: "" })
    def error = nil
  end

  setup do
    @user = User.create!(email: "stop@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @source = @org.servers.create!(name: "box-a", status: "online", ip_address: "10.0.0.1", ssh_key: key, ssh_user: "deploy")
    @target = @org.servers.create!(name: "box-b", status: "online", ip_address: "10.0.0.2", ssh_key: key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git")
  end

  def run_tool(**over)
    ConductorAppTool.new(user: @user).call({ "action" => "stop", "app_name" => "Appone" }.merge(over.transform_keys(&:to_s)))
  end

  test "removes the app's containers on the named target server, scoped by service label" do
    seen = []
    SshConnection.stub(:new, ->(srv) { f = FakeSsh.new(srv); seen << f; f }) do
      res = run_tool(target_server_name: "box-b")
      assert res.success?, res.error
      assert_equal 2, res.value[:removed_container_count]
      assert_equal "box-b", res.value[:server]
    end
    ssh = seen.last
    assert_equal @target, ssh.server, "ran on the TARGET box, not the app's home"
    cmd = ssh.commands.first
    assert_includes cmd, "docker rm -f"
    assert_includes cmd, "label=service=", "scoped to this app's service — can't touch other apps"
  end

  test "defaults to the app's own server when no target is given" do
    seen = []
    SshConnection.stub(:new, ->(srv) { f = FakeSsh.new(srv); seen << f; f }) do
      run_tool
    end
    assert_equal @source, seen.last.server
  end

  test "rejects a native app (docker-only)" do
    native = @org.apps.create!(name: "Nat", slug: "nat", server: @source, deploy_method: "native",
                               repository_url: "https://github.com/x/n.git")
    res = ConductorAppTool.new(user: @user).call("action" => "stop", "app_name" => "Nat")
    refute res.success?
    assert_match(/only/i, res.error)
  end

  test "an unknown app is a clean failure" do
    res = run_tool(app_name: "Nope")
    refute res.success?
    assert_match(/not found/i, res.error)
  end
end
