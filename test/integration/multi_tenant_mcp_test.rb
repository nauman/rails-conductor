require "test_helper"

# Multi-tenant MCP: a per-user/per-org ApiToken authenticates to the MCP server,
# runs as that user, and is scoped to their organizations — it cannot see or act
# on another org's apps. The legacy shared CONDUCTOR_MCP_TOKEN keeps global scope.
class MultiTenantMcpTest < ActionDispatch::IntegrationTest
  setup do
    @user_a = User.create!(email: "a@example.com")
    @org_a = Organization.create_for(@user_a, name: "Org A")
    @user_b = User.create!(email: "b@example.com")
    @org_b = Organization.create_for(@user_b, name: "Org B")
    @app_a = @org_a.apps.create!(name: "app-a", slug: "app-a")
    @app_b = @org_b.apps.create!(name: "app-b", slug: "app-b")
    raw, = ApiToken.generate(user: @user_a, name: "mcp", organization: @org_a)
    @token_a = raw
  end

  def call_tool(name, input, token:)
    post "/mcp/call", params: { name: name, input: input },
         headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  test "an invalid bearer token is rejected" do
    call_tool("fleet_status", {}, token: "not-a-real-token")
    assert_response :unauthorized
  end

  test "a per-user API token authenticates and runs as that user" do
    call_tool("fleet_status", {}, token: @token_a)
    assert_response :success
    assert_equal @user_a, McpCall.last.user
  end

  test "a per-user token can act on its own org's app" do
    call_tool("deploy_app", { app_name: "app-a" }, token: @token_a)
    # The app is found (scoping allows the user's own org); it may then fail for
    # other reasons (not deployable), but never the cross-org 'App not found'.
    refute_match(/App not found/, response.body)
  end

  test "a per-user token cannot see or act on another org's app" do
    call_tool("deploy_app", { app_name: "app-b" }, token: @token_a)
    assert_response :unprocessable_entity
    assert_match(/App not found/, response.body)
    assert_equal 0, @app_b.deployments.count, "must not deploy another org's app"
  end

  test "a token bound to one org can't act on another org the user also belongs to" do
    @org_b.add_member(@user_a) # user_a now belongs to org_b too...
    # ...but @token_a is bound to org_a, so it still can't touch app-b.
    call_tool("deploy_app", { app_name: "app-b" }, token: @token_a)
    assert_response :unprocessable_entity
    assert_match(/App not found/, response.body)
  end

  test "a read-only token can read but not deploy" do
    raw, = ApiToken.generate(user: @user_a, name: "ro", organization: @org_a, scope: "read")
    call_tool("deploy_app", { app_name: "app-a" }, token: raw)
    assert_response :unprocessable_entity
    assert_match(/read-only/, response.body)

    call_tool("fleet_status", {}, token: raw)
    assert_response :success
  end

  test "a per-user token cannot create resources in another org (org_id escalation)" do
    call_tool("create_app", { name: "sneaky", organization_id: @org_b.id }, token: @token_a)
    assert_response :unprocessable_entity
    assert_match(/Not authorized/, response.body)
  end

  test "a non-admin token cannot configure the instance-wide GitHub App" do
    call_tool("set_github_app", { app_id: "1", private_key: "x" }, token: @token_a)
    assert_response :unprocessable_entity
    assert_match(/Admin only/, response.body)
  end

  test "the legacy shared admin token keeps global scope" do
    admin = User.create!(email: "admin@example.com", admin: true)
    admin.ensure_personal_organization!
    original = ENV["CONDUCTOR_MCP_TOKEN"]
    ENV["CONDUCTOR_MCP_TOKEN"] = "legacy-shared"
    call_tool("deploy_app", { app_name: "app-b" }, token: "legacy-shared")
    refute_match(/App not found/, response.body) # admin sees every org's apps
  ensure
    ENV["CONDUCTOR_MCP_TOKEN"] = original
  end
end
