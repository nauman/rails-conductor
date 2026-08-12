require "test_helper"

# The conductor_runbook MCP tool manages a per-app deploy runbook + checklist,
# and stays org-scoped like every other mutating tool.
class ConductorRunbookTest < ActionDispatch::IntegrationTest
  setup do
    FleetRecipes.seed!
    @user_a = User.create!(email: "a@example.com")
    @org_a = Organization.create_for(@user_a, name: "Org A")
    @app_a = @org_a.apps.create!(name: "app-a", slug: "app-a")

    @user_b = User.create!(email: "b@example.com")
    @org_b = Organization.create_for(@user_b, name: "Org B")
    @app_b = @org_b.apps.create!(name: "app-b", slug: "app-b")
    AppRunbook.new(@app_b).add_item(content: "b-secret-step")
    @item_b = Jazari.resolve(target: FleetCanon.target_for(@app_b)).checklist.last

    raw, = ApiToken.generate(user: @user_a, name: "mcp", organization: @org_a, scope: "deploy")
    @token = raw
  end

  def call_tool(input)
    post "/mcp/call", params: { name: "conductor_runbook", input: input },
         headers: { "Authorization" => "Bearer #{@token}" }, as: :json
  end

  test "set_runbook stores the markdown runbook in jazari" do
    call_tool(action: "set_runbook", app_name: "app-a", runbook: "## Deploy app-a\n1. boot db")
    assert_response :success
    assert_equal "## Deploy app-a\n1. boot db", Jazari.resolve(target: FleetCanon.target_for(@app_a)).description
    assert_nil @app_a.reload.deploy_runbook
  end

  test "add_item then check_item then reset drive the checklist" do
    call_tool(action: "add_item", app_name: "app-a", content: "restore prod DB")
    assert_response :success
    item = Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.find { |row| row[:text] == "restore prod DB" }
    assert item[:required]
    assert_kind_of String, item[:id]

    call_tool(action: "check_item", app_name: "app-a", item_id: item[:id])
    assert Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.find { |row| row[:id] == item[:id] }[:done]
    assert_equal "user:#{@user_a.id}", AppRunbook.new(@app_a).last_run_summary[:actor_ref]

    call_tool(action: "evidence", item_id: item[:id], kind: "note", value: "deploy-123")
    assert_response :success
    assert_equal "deploy-123", AppRunbook.new(@app_a).last_run_summary[:evidence].last["value"]

    call_tool(action: "reset", app_name: "app-a")
    assert_not Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.find { |row| row[:id] == item[:id] }[:done]
    assert_nil @app_a.deploy_checklist_items.reload.first
  end

  test "get returns the runbook + checklist snapshot" do
    call_tool(action: "set_runbook", app_name: "app-a", runbook: "steps")
    call_tool(action: "add_item", app_name: "app-a", content: "one")
    call_tool(action: "get", app_name: "app-a")
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "steps", body.dig("result", "runbook")
    assert_includes body.dig("result", "checklist").map { |item| item["content"] }, "one"
  end

  test "cannot read or mutate another org's runbook/checklist" do
    call_tool(action: "get", app_name: "app-b")
    assert_match(/App not found/, response.body)

    call_tool(action: "check_item", item_id: @item_b[:id])
    assert_match(/Checklist item not found/, response.body)
    assert_not Jazari.resolve(target: FleetCanon.target_for(@app_b)).checklist.last[:done], "must not check another org's item"

    call_tool(action: "remove_item", item_id: @item_b[:id])
    assert_equal "b-secret-step", Jazari.resolve(target: FleetCanon.target_for(@app_b)).checklist.last[:text], "must not delete another org's item"
  end

  test "a read-only token cannot manage runbooks" do
    ro, = ApiToken.generate(user: @user_a, name: "ro", organization: @org_a, scope: "read")
    post "/mcp/call", params: { name: "conductor_runbook", input: { action: "set_runbook", app_name: "app-a", runbook: "x" } },
         headers: { "Authorization" => "Bearer #{ro}" }, as: :json
    assert_match(/read-only/, response.body)
    assert_nil Jazari::Runbook.find_by(runbookable_type: "App", runbookable_id: @app_a.id)
  end
end
