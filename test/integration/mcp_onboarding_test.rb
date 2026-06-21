require "test_helper"

# End-to-end check that the MCP HTTP endpoint can drive resource creation and
# that the internal `_organization` audit key never leaks to the client.
class McpOnboardingTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "mcp-admin@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    @token = "test-mcp-token"
    ENV["CONDUCTOR_MCP_TOKEN"] = @token
  end

  teardown { ENV.delete("CONDUCTOR_MCP_TOKEN") }

  def auth = { "Authorization" => "Bearer #{@token}" }

  test "register_server over MCP creates a server and strips _organization" do
    post "/mcp/call",
      params: { name: "conductor_server",
                input: { action: "register", name: "edge-1", ip_address: "10.0.0.9", ssh_user: "deploy" } },
      headers: auth, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["result"]
    refute body["result"].key?("_organization"), "internal _organization key leaked to client"
    assert Server.exists?(name: "edge-1")
  end

  test "create_app surfaces notes in fleet_status output" do
    server = @org.servers.create!(name: "host", status: "online")
    @org.apps.create!(name: "Kuickr", server: server, deploy_method: "docker", notes: "kamal deploy")

    post "/mcp/call", params: { name: "conductor_read", input: { action: "fleet_status" } }, headers: auth, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    app = body["result"].flat_map { |s| s["apps"] }.find { |a| a["name"] == "Kuickr" }
    assert_equal "kamal deploy", app["notes"]
  end
end
