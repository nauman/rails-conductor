require "test_helper"

# The standard JSON-RPC transport at POST /mcp (what `claude mcp add
# --transport http` speaks). Shares tool dispatch with the REST surface.
class McpRpcTransportTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email: "admin@example.com", admin: true)
    @admin.ensure_personal_organization!
    @token = "test-mcp-token"
  end

  def auth_headers
    { "Authorization" => "Bearer #{@token}" }
  end

  def rpc(body, headers: auth_headers)
    post "/mcp", params: body.to_json, headers: headers.merge("Content-Type" => "application/json")
    JSON.parse(response.body) unless response.body.blank?
  end

  def with_token
    original = ENV["CONDUCTOR_MCP_TOKEN"]
    ENV["CONDUCTOR_MCP_TOKEN"] = @token
    yield
  ensure
    ENV["CONDUCTOR_MCP_TOKEN"] = original
  end

  test "initialize returns protocol version, capabilities, and server info" do
    with_token do
      json = rpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })
      assert_response :success
      assert_equal "2.0", json["jsonrpc"]
      assert_equal 1, json["id"]
      assert json["result"]["protocolVersion"].present?
      assert json["result"]["capabilities"]["tools"]
      assert_equal "conductor", json["result"]["serverInfo"]["name"]
    end
  end

  test "tools/list returns the registry tools in MCP shape" do
    with_token do
      json = rpc({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })
      tools = json["result"]["tools"]
      assert_equal ToolRegistry.definitions.size, tools.size
      first = tools.first
      assert first.key?("name")
      assert first.key?("description")
      assert first.key?("inputSchema"), "must use MCP camelCase inputSchema"
    end
  end

  test "tools/call runs the tool and returns text content, and logs the call" do
    with_token do
      ToolRegistry.stub(:call, Result.ok({ "servers" => 3 })) do
        assert_difference -> { McpCall.count }, 1 do
          @json = rpc({ jsonrpc: "2.0", id: 3, method: "tools/call",
                        params: { name: "conductor_read", arguments: { action: "fleet_status" } } })
        end
      end
      assert_response :success
      assert_equal false, @json["result"]["isError"]
      text = @json["result"]["content"].first["text"]
      assert_includes text, "servers"
    end
  end

  test "a tool failure is reported as isError, not a protocol error" do
    with_token do
      ToolRegistry.stub(:call, Result.fail("boom")) do
        json = rpc({ jsonrpc: "2.0", id: 4, method: "tools/call",
                     params: { name: "conductor_app", arguments: { action: "deploy" } } })
        assert_nil json["error"], "tool errors are not JSON-RPC errors"
        assert_equal true, json["result"]["isError"]
        assert_includes json["result"]["content"].first["text"], "boom"
      end
    end
  end

  test "the _organization marker is stripped from tools/call output" do
    with_token do
      ToolRegistry.stub(:call, Result.ok({ "ok" => true, _organization: @admin.organizations.first })) do
        json = rpc({ jsonrpc: "2.0", id: 5, method: "tools/call",
                     params: { name: "conductor_server", arguments: { action: "register" } } })
        refute_includes json["result"]["content"].first["text"], "_organization"
      end
    end
  end

  test "notifications get 202 and no body" do
    with_token do
      post "/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
           headers: auth_headers.merge("Content-Type" => "application/json")
      assert_response :accepted
      assert response.body.blank?
    end
  end

  test "an unknown method returns a JSON-RPC method-not-found error" do
    with_token do
      json = rpc({ jsonrpc: "2.0", id: 6, method: "does/not/exist", params: {} })
      assert_equal(-32601, json["error"]["code"])
    end
  end

  test "malformed JSON returns a parse error" do
    with_token do
      post "/mcp", params: "{not json", headers: auth_headers.merge("Content-Type" => "application/json")
      json = JSON.parse(response.body)
      assert_equal(-32700, json["error"]["code"])
    end
  end

  test "a missing or bad token is rejected" do
    json = rpc({ jsonrpc: "2.0", id: 7, method: "initialize", params: {} }, headers: {})
    assert_response :unauthorized
    assert_equal(-32001, json["error"]["code"])
  end

  test "GET /mcp is method not allowed (no server-initiated stream)" do
    with_token do
      get "/mcp", headers: auth_headers
      assert_response :method_not_allowed
    end
  end
end
