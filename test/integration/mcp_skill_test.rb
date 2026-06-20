require "test_helper"

class McpSkillTest < ActionDispatch::IntegrationTest
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

  test "GET /mcp/skill returns the conductor skill doc" do
    with_token do
      get "/mcp/skill", headers: auth_headers
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "conductor", body["name"]
      assert_includes body["skill"], "fleet_status"
      assert_includes body["skill"], "Conductor"
    end
  end

  test "GET /mcp/skill requires auth" do
    get "/mcp/skill"
    assert_response :unauthorized
  end
end
