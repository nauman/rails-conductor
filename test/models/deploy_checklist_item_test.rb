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
    @app.update!(deploy_runbook: "## Deploy steps")
    @app.deploy_checklist_items.create!(content: "a").check!
    @app.deploy_checklist_items.create!(content: "b")
    summary = @app.runbook_summary
    assert_equal "## Deploy steps", summary[:runbook]
    assert_equal({ done: 1, total: 2 }, summary[:checklist_progress])

    assert_difference -> { DeployChecklistItem.count }, -2 do
      @app.destroy!
    end
  end
end
