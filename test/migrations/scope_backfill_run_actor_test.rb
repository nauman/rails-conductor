require "test_helper"
require Rails.root.join("db/migrate/20260811090001_backfill_jazari_from_deploy_checklists")
require Rails.root.join("db/migrate/20260811171026_scope_backfill_run_actor")

# The rollback hazard: the backfill wrote runs with actor_ref "migration" and its
# `down` deleted every run carrying that value. The string is reusable, so an
# unrelated rollback would take a later migration's work with it. These tests are
# mostly about what must survive.
class ScopeBackfillRunActorTest < ActiveSupport::TestCase
  SCOPED = "migration:20260811090001".freeze

  setup do
    @user = User.create!(email: "scope@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Scope Co")
    @server = Server.create!(name: "box", status: "online", organization: @org, edge_type: "caddy")
    @app = @org.apps.create!(name: "Scoped", slug: "scoped", server: @server,
                             deploy_method: "kamal", port: 9083, deploy_runbook: "notes")
    FleetRecipes.seed!
    @app.deploy_checklist_items.create!(content: "one", done: true, done_at: 1.hour.ago)
    BackfillJazariFromDeployChecklists.new.tap { |m| m.verbose = false }.up
  end

  def repair = ScopeBackfillRunActor.new.tap { |m| m.verbose = false }.up
  def runbook = Jazari::Runbook.find_by(runbookable_type: "App", runbookable_id: @app.id)

  test "a legacy-actor run for a backfilled app is rescoped to this migration" do
    Jazari::Run.where(subject_type: "App", subject_id: @app.id).update_all(actor_ref: "migration")
    runbook.update_columns(origin: "migration")

    repair

    assert_equal [ SCOPED ], Jazari::Run.where(subject_type: "App", subject_id: @app.id).pluck(:actor_ref).uniq
    assert_equal SCOPED, runbook.reload.origin
  end

  # The whole point: another migration's run sharing the actor string must survive.
  test "an unrelated run that merely shares the actor string is untouched" do
    other = Jazari::Run.create!(recipe_id: "caddy-mode-app", source_digest: "d", actor_ref: "migration",
                                started_at: Time.current, started_on: Date.current,
                                checklist_snapshot: [], subject_type: nil, subject_id: nil)

    repair

    assert_equal "migration", other.reload.actor_ref, "a run with no App subject is not ours to rescope"
  end

  test "a human's run is never rescoped" do
    mine = Jazari::Run.create!(recipe_id: "caddy-mode-app", source_digest: "d", actor_ref: "nauman",
                               started_at: Time.current, started_on: Date.current,
                               checklist_snapshot: [], subject_type: "App", subject_id: @app.id)

    repair

    assert_equal "nauman", mine.reload.actor_ref
  end

  test "rollback of the backfill no longer deletes a foreign run with the same actor" do
    foreign = Jazari::Run.create!(recipe_id: "caddy-mode-app", source_digest: "d", actor_ref: "migration",
                                  started_at: Time.current, started_on: Date.current,
                                  checklist_snapshot: [], subject_type: nil, subject_id: nil)

    BackfillJazariFromDeployChecklists.new.tap { |m| m.verbose = false }.down

    assert Jazari::Run.exists?(foreign.id),
      "a rollback must not delete runs that merely share a reusable actor string"
  end
end
