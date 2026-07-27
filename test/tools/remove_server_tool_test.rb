require "test_helper"

class RemoveServerToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rm-server@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
  end

  test "removes a server with no apps attached" do
    server = @org.servers.create!(name: "dead-box", status: "online", ip_address: "10.0.0.9")
    res = ConductorServerTool.new(user: @user).call("action" => "remove", "server_id" => server.id)
    assert res.success?, res.error
    assert res.value[:removed]
    assert_equal "dead-box", res.value[:server]
    assert_equal 0, res.value[:detached_apps]
    assert_nil Server.find_by(id: server.id)
  end

  test "refuses to remove a server that still has apps (no force)" do
    server = @org.servers.create!(name: "busy-box", status: "online", ip_address: "10.0.0.10")
    @org.apps.create!(name: "App", slug: "app", server: server, deploy_method: "kamal")
    res = ConductorServerTool.new(user: @user).call("action" => "remove", "server_name" => "busy-box")
    refute res.success?
    assert_match(/still has 1 app/, res.error)
    assert Server.find_by(id: server.id), "server should not be deleted"
  end

  test "force removes a server and detaches its apps" do
    server = @org.servers.create!(name: "busy-box2", status: "online", ip_address: "10.0.0.11")
    app = @org.apps.create!(name: "App2", slug: "app2", server: server, deploy_method: "kamal")
    res = ConductorServerTool.new(user: @user).call("action" => "remove", "server_id" => server.id, "force" => true)
    assert res.success?, res.error
    assert_equal 1, res.value[:detached_apps]
    assert_nil Server.find_by(id: server.id)
    assert_nil app.reload.server_id, "app should be detached (nullify)"
  end

  test "reports an unknown server" do
    res = ConductorServerTool.new(user: @user).call("action" => "remove", "server_id" => 999_999)
    refute res.success?
    assert_includes res.error, "Server not found"
  end
end
