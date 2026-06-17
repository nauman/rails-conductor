require "test_helper"

class McpCallLoggingTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin@example.com", admin: true)
    @admin.ensure_personal_organization!
    @token = "test-mcp-token"
  end

  def auth_headers
    { "Authorization" => "Bearer #{@token}" }
  end

  def with_token
    original = ENV["CONDUCTOR_MCP_TOKEN"]
    ENV["CONDUCTOR_MCP_TOKEN"] = @token
    yield
  ensure
    ENV["CONDUCTOR_MCP_TOKEN"] = original
  end

  test "a successful MCP call is logged" do
    with_token do
      ToolRegistry.stub(:call, Result.ok({ "ok" => true })) do
        assert_difference -> { McpCall.count }, 1 do
          post "/mcp/call", params: { name: "fleet_status", input: {} }, headers: auth_headers, as: :json
        end
      end
    end

    assert_response :success
    call = McpCall.last
    assert_equal "fleet_status", call.tool_name
    assert_equal "success", call.status
    assert_equal @admin, call.user
    assert call.duration_ms >= 0
  end

  test "a failed MCP call is logged with failed status" do
    with_token do
      ToolRegistry.stub(:call, Result.fail("boom")) do
        assert_difference -> { McpCall.count }, 1 do
          post "/mcp/call", params: { name: "deploy_app", input: {} }, headers: auth_headers, as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    assert_equal "failed", McpCall.last.status
    assert_equal "boom", McpCall.last.error
  end

  test "an unauthorized call is not logged" do
    with_token do
      assert_no_difference -> { McpCall.count } do
        post "/mcp/call", params: { name: "fleet_status", input: {} }, headers: { "Authorization" => "Bearer wrong" }, as: :json
      end
    end
    assert_response :unauthorized
  end

  test "a webmaster can view the MCP activity log" do
    McpCall.record(tool_name: "fleet_status", arguments: {}, result: Result.ok({}), duration_ms: 5)
    ps = Passwordless::Session.create!(authenticatable: @admin)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"

    get admin_mcp_calls_path

    assert_response :success
    assert_match "MCP Activity", @response.body
    assert_match "fleet_status", @response.body
  end
end
