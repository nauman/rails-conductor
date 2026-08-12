require "test_helper"

class LegacyRunbookAuditTest < ActiveSupport::TestCase
  setup do
    FleetRecipes.seed!
    org = Organization.create!(name: "Acme")
    @app = org.apps.create!(name: "app", slug: "app")
  end

  test "reports parity for the migrated legacy shape" do
    legacy = @app.deploy_checklist_items.create!(content: "verify", done: true, required: false)
    target = FleetCanon.target_for(@app)
    resolved = Jazari.resolve(target: target)
    Jazari.customize(target: target, expected_revision: resolved.revision,
                     topic: resolved.topic, description: "notes",
                     checklist: [{ id: legacy.id.to_s, text: legacy.content, done: true, required: false }])
    @app.update!(deploy_runbook: "notes")

    result = LegacyRunbookAudit.call
    assert result.clean?, result.issues.inspect
    assert_equal 1, result.legacy_items
    assert_equal 1, result.jazari_items
  end

  test "reports checklist drift" do
    legacy = @app.deploy_checklist_items.create!(content: "verify")
    target = FleetCanon.target_for(@app)
    resolved = Jazari.resolve(target: target)
    Jazari.customize(target: target, expected_revision: resolved.revision,
                     topic: resolved.topic, description: "",
                     checklist: [{ id: legacy.id.to_s, text: "different" }])

    result = LegacyRunbookAudit.call
    assert_not result.clean?
    assert_includes result.issues.map { |issue| issue[:field] }, "checklist"
  end
end
