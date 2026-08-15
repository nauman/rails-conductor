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

  # The reported defect: two check_item calls returned an error and had BOTH
  # applied. A caller's natural response to a reported failure is to retry, and a
  # retry against a half-applied two-phase write is how a double record happens.
  #
  # The shape matters — a same-revision tick passes today and proves nothing. The
  # item must be added while a run is ALREADY OPEN, so it post-dates that run's
  # checklist snapshot and Jazari.tick cannot record it.
  test "ticking an item added mid-run succeeds and the run records it" do
    call_tool(action: "add_item", app_name: "app-a", content: "opening step")
    opening = Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.last
    call_tool(action: "check_item", app_name: "app-a", item_id: opening[:id])
    assert AppRunbook.new(@app_a).last_run_summary[:open], "a run must be open for this to test anything"

    call_tool(action: "add_item", app_name: "app-a", content: "discovered mid-deploy")
    late = Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.last

    call_tool(action: "check_item", app_name: "app-a", item_id: late[:id])

    assert_response :success
    body = JSON.parse(response.body)
    persisted = Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.find { |row| row[:id] == late[:id] }
    assert persisted[:done], "the tick must persist"
    refute_includes body.to_s, "unknown checklist item", "a committed tick must never be reported as failed"

    # jazari 0.6.0 widens the run's snapshot for an item added to the SUBJECT's own
    # runbook, so the evidence is complete rather than merely honest about a gap.
    run = Jazari::Run.where(subject_type: "App", subject_id: @app_a.id).order(:id).last
    tick = (run.ticks || []).find { |t| t["id"] == late[:id] }
    assert tick, "the run must record a tick for an item added while it was open"
    assert_equal true, tick["done"]
    refute_includes body.to_s, "does not record it", "there is no gap to report once the snapshot widens"
  end

  test "a phase-two failure rolls the tick back so the reported failure is true" do
    call_tool(action: "add_item", app_name: "app-a", content: "atomic step")
    item = Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.last

    Jazari.stub(:tick, ->(**) { raise Jazari::RevisionConflict, "expected 1, actual 2" }) do
      assert_raises(Jazari::RevisionConflict) do
        AppRunbook.new(@app_a).check_item(item_id: item[:id], done: true)
      end
    end

    refute Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.find { |row| row[:id] == item[:id] }[:done],
      "a reported failure must leave nothing committed"
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

  test "check_item scopes a repeated opaque id to the named app" do
    other = @org_a.apps.create!(name: "app-c", slug: "app-c")
    customize_with_deploy_item(@app_a)
    customize_with_deploy_item(other)
    item_a = Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.last
    item_c = Jazari.resolve(target: FleetCanon.target_for(other)).checklist.last
    assert_equal item_a[:id], item_c[:id], "the regression requires a repeated recipe-local id"

    call_tool(action: "check_item", app_id: other.id, item_id: item_c[:id])

    assert_not Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.last[:done]
    assert Jazari.resolve(target: FleetCanon.target_for(other)).checklist.last[:done]
  end

  test "check_item refuses an unscoped id that belongs to more than one visible app" do
    other = @org_a.apps.create!(name: "app-c", slug: "app-c")
    customize_with_deploy_item(@app_a)
    customize_with_deploy_item(other)
    item_id = Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.last[:id]

    call_tool(action: "check_item", item_id: item_id)

    assert_match(/ambiguous|app_id|app_name/i, response.body)
    assert_not Jazari.resolve(target: FleetCanon.target_for(@app_a)).checklist.last[:done]
    assert_not Jazari.resolve(target: FleetCanon.target_for(other)).checklist.last[:done]
  end

  test "a read-only token cannot manage runbooks" do
    ro, = ApiToken.generate(user: @user_a, name: "ro", organization: @org_a, scope: "read")
    post "/mcp/call", params: { name: "conductor_runbook", input: { action: "set_runbook", app_name: "app-a", runbook: "x" } },
         headers: { "Authorization" => "Bearer #{ro}" }, as: :json
    assert_match(/read-only/, response.body)
    assert_nil Jazari::Runbook.find_by(runbookable_type: "App", runbookable_id: @app_a.id)
  end

  private

  def customize_with_deploy_item(app)
    target = FleetCanon.target_for(app)
    resolved = Jazari.resolve(target: target)
    Jazari.customize(target: target, expected_revision: resolved.revision,
                     topic: "Deploy", description: "Deploy safely",
                     checklist: [ { id: "deploy", text: "Deploy", required: true, done: false } ])
  end
end
