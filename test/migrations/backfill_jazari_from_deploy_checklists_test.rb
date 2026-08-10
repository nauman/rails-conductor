require "test_helper"
require Rails.root.join("db/migrate/20260811090001_backfill_jazari_from_deploy_checklists")

# Phase 2 moves live deploy checklists onto jazari. The migration is worth testing
# for what it must NOT do more than for what it does: operators are mid-procedure,
# and the failure mode is silent — a reset `done` flag or a dropped step looks
# exactly like a checklist nobody had started.
class BackfillJazariFromDeployChecklistsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "backfill@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Backfill Co")
    @server = Server.create!(name: "caddy-box", status: "online", organization: @org, edge_type: "caddy")
    @app = @org.apps.create!(name: "Midflight", slug: "midflight", server: @server,
                             deploy_method: "kamal", port: 9081, domain: "midflight.test",
                             deploy_runbook: "Deploy notes that predate the gem.")
    FleetRecipes.seed!
  end

  def item(content, done: false, done_at: nil, required: true, position: nil)
    @app.deploy_checklist_items.create!(content: content, done: done, done_at: done_at,
                                        required: required, position: position)
  end

  def run_migration = BackfillJazariFromDeployChecklists.new.tap { |m| m.verbose = false }.up

  def runbook = Jazari::Runbook.find_by(runbookable_type: "App", runbookable_id: @app.id)

  test "an in-flight checklist keeps its done flags" do
    item("free the port", done: true, done_at: 2.days.ago)
    item("deploy")
    item("verify origin")

    run_migration

    assert_equal [ true, false, false ], runbook.checklist.map { |i| i["done"] }
  end

  test "item ids carry across verbatim so quoted ids keep resolving" do
    first = item("free the port")
    second = item("deploy")

    run_migration

    assert_equal [ first.id.to_s, second.id.to_s ], runbook.checklist.map { |i| i["id"] }
  end

  test "items are re-indexed by array order, not by a position that may have gaps" do
    later = item("deploy", position: 40)
    earlier = item("free the port", position: 7)

    run_migration

    assert_equal [ earlier.id.to_s, later.id.to_s ], runbook.checklist.map { |i| i["id"] }
  end

  test "it stops rather than fixing forward when the item count does not survive" do
    item("free the port")

    # Nothing in normal data can lose an item — the guard exists for the case the
    # traversal itself is wrong, so it is provoked here rather than staged. The
    # assertion under test is that a shortfall RAISES instead of committing a
    # partial move that reads like a complete one.
    DeployChecklistItem.stub(:count, 99) do
      error = assert_raises(RuntimeError) { run_migration }
      assert_match(/backfill lost items/, error.message)
    end

    assert_nil runbook, "a failed census must not leave a half-written runbook"
  end

  test "an app already carrying a runbook is skipped, not clobbered" do
    item("free the port")
    Jazari::Runbook.create!(runbookable_type: "App", runbookable_id: @app.id,
                            recipe_id: "caddy-mode-app", topic: "Operator's own",
                            description: "hand written", checklist: [])

    run_migration

    assert_equal "Operator's own", runbook.topic
    assert_equal "hand written", runbook.description
  end

  test "a per-app closed run preserves the done_at values the item schema cannot hold" do
    at = 3.days.ago.change(usec: 0)
    item("free the port", done: true, done_at: at)
    item("deploy", done: true, done_at: at + 1.hour)

    run_migration

    run = Jazari::Run.find_by(subject_type: "App", subject_id: @app.id)
    assert run, "expected a backfilled run"
    assert_equal "completed", run.outcome
    assert_equal "migration", run.actor_ref
    assert_equal at.utc.to_i, run.started_at.to_i
    assert_equal (at + 1.hour).utc.to_i, run.finished_at.to_i
    assert_equal 2, run.ticks.length
  end

  test "an optional step left undone does not make the run incomplete" do
    item("free the port", done: true, done_at: 1.day.ago)
    item("tidy dead containers", required: false)

    run_migration

    assert_equal "completed", Jazari::Run.find_by(subject_id: @app.id).outcome
  end

  test "no run is written when nothing carries a timestamp" do
    item("free the port")

    run_migration

    assert_nil Jazari::Run.find_by(subject_type: "App", subject_id: @app.id)
  end

  test "the runbook points at the recipe the app's shape resolves to" do
    item("free the port")

    run_migration

    assert_equal "caddy-mode-app", runbook.recipe_id
    assert_equal "Deploy notes that predate the gem.", runbook.description
  end
end
