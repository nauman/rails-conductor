require "test_helper"

class DeployChecklistItemTest < ActiveSupport::TestCase
  setup do
    org = Organization.create!(name: "Acme")
    @app = org.apps.create!(name: "app", slug: "app")
  end

  test "content is required" do
    item = @app.deploy_checklist_items.new(content: "")
    assert_not item.valid?
  end

  test "position auto-increments per app in append order" do
    a = @app.deploy_checklist_items.create!(content: "first")
    b = @app.deploy_checklist_items.create!(content: "second")
    assert_operator b.position, :>, a.position
    assert_equal %w[first second], @app.deploy_checklist_items.reload.map(&:content)
  end

  test "check! and uncheck! toggle done + done_at" do
    item = @app.deploy_checklist_items.create!(content: "run migrations")
    item.check!
    assert item.done?
    assert_not_nil item.done_at
    item.uncheck!
    assert_not item.done?
    assert_nil item.done_at
  end

  test "runbook_summary reports progress and destroys items with the app" do
    FleetRecipes.seed!
    AppRunbook.new(@app).set_runbook(description: "## Deploy steps")
    AppRunbook.new(@app).add_item(content: "a")
    AppRunbook.new(@app).add_item(content: "b")
    item = Jazari.resolve(target: FleetCanon.target_for(@app)).checklist.first
    AppRunbook.new(@app).check_item(item_id: item[:id], done: true)
    summary = @app.runbook_summary
    assert_equal "## Deploy steps", summary[:runbook]
    assert_equal({ done: 1, total: 5, percent: 20 }, summary[:checklist_progress])

    assert_no_difference -> { DeployChecklistItem.count } do
      @app.destroy!
    end
  end

  test "production legacy writes are blocked" do
    Rails.env.stub(:production?, true) do
      item = @app.deploy_checklist_items.new(content: "blocked")
      assert_raises(ActiveRecord::RecordNotSaved) { item.save! }
    end
  end
end
