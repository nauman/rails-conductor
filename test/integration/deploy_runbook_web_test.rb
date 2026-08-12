require "test_helper"

class DeployRunbookWebTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    FleetRecipes.seed!
    @owner = User.create!(email: "owner@example.com")
    @org = Organization.create_for(@owner, name: "Acme")
    @web_app = @org.apps.create!(name: "app", slug: "app")
    sign_in_as(@owner)
  end

  test "app show renders the runbook + checklist section" do
    get app_path(@web_app)
    assert_response :success
    assert_select "#runbook"
  end

  test "an operator can save the runbook" do
    patch update_runbook_app_path(@web_app), params: { app: { deploy_runbook: "## steps" } }
    assert_redirected_to app_path(@web_app, anchor: "runbook")
    assert_equal "## steps", Jazari.resolve(target: FleetCanon.target_for(@web_app)).description
    assert_nil @web_app.reload.deploy_runbook
  end

  test "an operator can add, check, and remove checklist items" do
    post app_deploy_checklist_items_path(@web_app), params: { deploy_checklist_item: { content: "boot db" } }
    item = Jazari.resolve(target: FleetCanon.target_for(@web_app)).checklist.find { |row| row[:text] == "boot db" }
    assert item

    patch app_deploy_checklist_item_path(@web_app, item[:id]), params: { deploy_checklist_item: { done: "1" } }
    assert Jazari.resolve(target: FleetCanon.target_for(@web_app)).checklist.find { |row| row[:id] == item[:id] }[:done]

    delete app_deploy_checklist_item_path(@web_app, item[:id])
    assert_nil Jazari.resolve(target: FleetCanon.target_for(@web_app)).checklist.find { |row| row[:id] == item[:id] }
  end

  test "a plain member cannot manage the runbook" do
    member = User.create!(email: "m@example.com")
    @org.add_member(member, role: :member)
    sign_in_as(member)
    patch update_runbook_app_path(@web_app), params: { app: { deploy_runbook: "x" } }
    assert_redirected_to root_path
    assert_nil Jazari::Runbook.find_by(runbookable_type: "App", runbookable_id: @web_app.id)
  end
end
