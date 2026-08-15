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

  # The ruling that produced this: a tick from a run that ENDED is not drift. The
  # legacy table has no run concept, so a per-item comparison manufactures a
  # difference that no amount of ticking closes. Green must therefore mean
  # "nothing unexplained" — and an unexplained difference must still fail, or the
  # exception file becomes a way to silence the check.
  test "a recorded exception is explained rather than failing the audit" do
    app = App.create!(name: "Legacy Ex", slug: "legacy-ex", organization: @org)
    app.deploy_checklist_items.create!(content: "ticked in a run that ended", done: true, position: 1)

    result = LegacyRunbookAudit.new.stub(:exceptions, [ { "app_id" => app.id, "field" => "checklist", "reason" => "superseded run" } ]) do |audit|
      audit.call
    end

    mine = result.explained.select { |e| e[:app_id] == app.id }
    assert_equal 1, mine.size, "the difference must be carried as explained, not discarded"
    assert_equal "superseded run", mine.first[:reason]
    refute result.issues.any? { |i| i[:app_id] == app.id && i[:field] == "checklist" },
      "an explained difference must not fail the audit"
    # ...and the exception is scoped to the field it names: this app's description
    # differs too, was never written down, and must still be reported.
    assert result.issues.any? { |i| i[:app_id] == app.id && i[:field] == "description" },
      "an exception for one field must not silence another"
  end

  test "an unexplained difference still fails" do
    app = App.create!(name: "Legacy Un", slug: "legacy-un", organization: @org)
    app.deploy_checklist_items.create!(content: "nobody wrote this down", done: true, position: 1)

    result = LegacyRunbookAudit.new.call

    assert result.issues.any? { |i| i[:app_id] == app.id }, "silence must not pass"
    refute result.clean?
  end
end
