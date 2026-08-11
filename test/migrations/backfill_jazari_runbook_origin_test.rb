require "test_helper"
require Rails.root.join("db/migrate/20260811090001_backfill_jazari_from_deploy_checklists")
require Rails.root.join("db/migrate/20260811090002_backfill_jazari_runbook_origin")

# 20260811090001 landed WITHOUT `origin`, ran, and created the runbooks. Editing that
# already-run migration to add provenance changed nothing, because its version was
# already in schema_migrations. This repairs the rows it left behind — and the danger
# is claiming rows it did not create, so most of these tests are about what it must
# NOT stamp.
class BackfillJazariRunbookOriginTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "origin@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Origin Co")
    @server = Server.create!(name: "caddy-box", status: "online", organization: @org, edge_type: "caddy")
    @app = @org.apps.create!(name: "Stamped", slug: "stamped", server: @server,
                             deploy_method: "kamal", port: 9082, domain: "stamped.test",
                             deploy_runbook: "notes")
    FleetRecipes.seed!
  end

  def item(content, done: false)
    @app.deploy_checklist_items.create!(content: content, done: done)
  end

  def backfill = BackfillJazariFromDeployChecklists.new.tap { |m| m.verbose = false }.up
  def repair = BackfillJazariRunbookOrigin.new.tap { |m| m.verbose = false }.up
  def runbook = Jazari::Runbook.find_by(runbookable_type: "App", runbookable_id: @app.id)

  test "stamps a runbook whose checklist ids are exactly the app's legacy item ids" do
    item("one", done: true)
    item("two")
    backfill
    runbook.update_columns(origin: nil) # reproduce the state production is in

    repair

    assert_equal "migration", runbook.reload.origin
  end

  test "the repaired row stops reading as an operator divergence" do
    item("one")
    backfill
    runbook.update_columns(origin: nil)
    target = FleetCanon.target_for(@app)
    skip "needs jazari >= 0.3 (origin)" unless Jazari.resolve(target: target).respond_to?(:diverged?)

    assert Jazari.resolve(target: target).diverged?, "the broken state: reads as a human's choice"

    repair

    refute Jazari.resolve(target: target).diverged?, "provenance says it was materialized"
    assert Jazari.resolve(target: target).inherited?
  end

  test "never claims a runbook whose checklist is not the legacy id set" do
    item("one")
    backfill
    runbook.update_columns(origin: nil,
                           checklist: [ { "id" => "handwritten", "text" => "an operator's own step",
                                          "done" => false, "required" => true } ])

    repair

    assert_nil runbook.reload.origin, "an operator's content must not be claimed as ours"
  end

  test "never overwrites an origin that is already set" do
    item("one")
    backfill
    runbook.update_columns(origin: "someone-else")

    repair

    assert_equal "someone-else", runbook.reload.origin
  end

  test "leaves an app with no legacy items alone" do
    other = @org.apps.create!(name: "Empty", slug: "empty", server: @server, deploy_method: "kamal")
    Jazari::Runbook.create!(runbookable_type: "App", runbookable_id: other.id,
                            recipe_id: "caddy-mode-app", topic: "t", description: "",
                            checklist: [ { "id" => "x", "text" => "y", "done" => false, "required" => true } ])

    repair

    assert_nil Jazari::Runbook.find_by(runbookable_id: other.id).origin
  end

  test "does not bump lock_version — agents hold revisions right now" do
    item("one")
    backfill
    runbook.update_columns(origin: nil)
    before = runbook.reload.lock_version

    repair

    assert_equal before, runbook.reload.lock_version,
      "bumping the revision would invalidate a checklist an operator is mid-way through"
  end

  test "down clears only what it set" do
    item("one")
    backfill
    runbook.update_columns(origin: nil)
    repair

    BackfillJazariRunbookOrigin.new.tap { |m| m.verbose = false }.down

    assert_nil runbook.reload.origin
  end
end
