require "test_helper"

# The conductor_runbook MCP tool manages a per-app deploy runbook + checklist,
# and stays org-scoped like every other mutating tool.
class ConductorRunbookTest < ActionDispatch::IntegrationTest
  setup do
    @user_a = User.create!(email: "a@example.com")
    @org_a = Organization.create_for(@user_a, name: "Org A")
    @app_a = @org_a.apps.create!(name: "app-a", slug: "app-a")

    @user_b = User.create!(email: "b@example.com")
    @org_b = Organization.create_for(@user_b, name: "Org B")
    @app_b = @org_b.apps.create!(name: "app-b", slug: "app-b")
    @item_b = @app_b.deploy_checklist_items.create!(content: "b-secret-step")

    raw, = ApiToken.generate(user: @user_a, name: "mcp", organization: @org_a, scope: "deploy")
    @token = raw
  end

  def call_tool(input)
    post "/mcp/call", params: { name: "conductor_runbook", input: input },
         headers: { "Authorization" => "Bearer #{@token}" }, as: :json
  end

  test "set_runbook stores the markdown runbook on the app" do
    call_tool(action: "set_runbook", app_name: "app-a", runbook: "## Deploy app-a\n1. boot db")
    assert_response :success
    assert_equal "## Deploy app-a\n1. boot db", @app_a.reload.deploy_runbook
  end

  test "add_item then check_item then reset drive the checklist" do
    call_tool(action: "add_item", app_name: "app-a", content: "restore prod DB")
    assert_response :success
    item = @app_a.deploy_checklist_items.sole
    assert item.required

    call_tool(action: "check_item", item_id: item.id)
    assert item.reload.done?

    call_tool(action: "reset", app_name: "app-a")
    assert_not item.reload.done?
  end

  test "get returns the runbook + checklist snapshot" do
    @app_a.update!(deploy_runbook: "steps")
    @app_a.deploy_checklist_items.create!(content: "one")
    call_tool(action: "get", app_name: "app-a")
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "steps", body.dig("result", "runbook")
    assert_equal 1, body.dig("result", "checklist").size
  end

  test "cannot read or mutate another org's runbook/checklist" do
    call_tool(action: "get", app_name: "app-b")
    assert_match(/App not found/, response.body)

    call_tool(action: "check_item", item_id: @item_b.id)
    assert_match(/Checklist item not found/, response.body)
    assert_not @item_b.reload.done?, "must not check another org's item"

    call_tool(action: "remove_item", item_id: @item_b.id)
    assert DeployChecklistItem.exists?(@item_b.id), "must not delete another org's item"
  end

  test "a read-only token cannot manage runbooks" do
    ro, = ApiToken.generate(user: @user_a, name: "ro", organization: @org_a, scope: "read")
    post "/mcp/call", params: { name: "conductor_runbook", input: { action: "set_runbook", app_name: "app-a", runbook: "x" } },
         headers: { "Authorization" => "Bearer #{ro}" }, as: :json
    assert_match(/read-only/, response.body)
    assert_nil @app_a.reload.deploy_runbook
  end
end
