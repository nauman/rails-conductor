require "test_helper"

# Resume becomes subject-scoped by composing `Jazari.resolve` against the canon.
#
# Before this, `situation` answered "what is broken" as a flat list and said nothing
# about what to DO — the procedure lived in a session log, a learnings file, or an
# agent's memory. Now each subject carries the ritual that governs its shape, its
# checklist progress, and whether the last run finished. Conductor composes; it does
# not duplicate: jazari owns the checklist, the run and the revision guard.
class FleetSituationRitualsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rituals@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Rituals Co")
    @caddy = Server.create!(name: "caddy-box", status: "online", organization: @org, edge_type: "caddy")
    @app = @org.apps.create!(name: "Ritualy", slug: "ritualy", server: @caddy,
                             deploy_method: "kamal", port: 9080, domain: "ritualy.test")
    FleetRecipes.seed!
  end

  def snapshot = FleetSituation.new(server_scope: Server.where(id: @caddy.id)).snapshot

  def subject_row = snapshot[:subjects].find { |s| s[:app] == "Ritualy" }

  test "each subject carries the ritual its shape resolves to" do
    row = subject_row

    assert row, "expected a subject row: #{snapshot[:subjects].inspect}"
    assert_equal "caddy-mode-app", row[:recipe_id]
    assert_match(/Caddy/i, row[:topic])
    assert row[:checklist][:total].positive?, "a resolved ritual must carry its steps"
  end

  test "the shape is reported alongside the ritual so the reason is visible" do
    row = subject_row

    assert_equal "kamal", row[:shape][:artifact]
    assert_equal "caddy", row[:shape][:edge]
    assert_equal "conductor", row[:shape][:driver]
  end

  test "an externally driven app resolves to its own ritual, not a deploy one" do
    @app.update!(deploy_hold: true, deploy_hold_reason: "deploys use repo bin/deploy-ssdnode")

    assert_equal "external-driver-app", subject_row[:recipe_id]
  end

  test "a subject with no customisation reports the canon state, not a missing runbook" do
    assert_equal "default", subject_row[:state],
      "an uncustomised subject resolves the canon live — that is not the same as absent"
  end

  test "a customised runbook is reported as diverged from its canon" do
    target = FleetCanon.target_for(@app)
    resolved = Jazari.resolve(target: target)
    Jazari.customize(target: target, expected_revision: resolved.revision,
                     topic: "Ritualy, the operator's way", description: "local", checklist: [ { id: "one", text: "step" } ])

    row = subject_row
    assert_equal "custom", row[:state]
    assert row[:diverged], "a customised subject must be visibly diverged, or a stale override is invisible"
  end

  test "the last run is surfaced so an unfinished ritual is not read as done" do
    assert_nil subject_row[:last_run], "no run yet"

    target = FleetCanon.target_for(@app)
    Jazari.open_run(target: target, actor_ref: "test")

    assert subject_row[:last_run].present?, "a started run must be visible at the resume point"
    assert_equal "test", subject_row[:last_run][:actor_ref]
  end

  test "resolving a subject never breaks the rest of the snapshot" do
    # A recipe that was never seeded resolves to jazari's empty fallback rather than
    # raising — a resume point that dies because one subject is odd is useless.
    FleetCanon.stub(:shape_for, { artifact: "kamal", driver: "conductor", edge: "caddy", recipe_id: "not-seeded" }) do
      row = subject_row
      assert row, "the subject must still appear"
      assert_equal "not-seeded", row[:recipe_id]
    end

    assert snapshot[:needs_attention].is_a?(Array)
  end

  # jazari 0.3 splits two things my code was conflating. `custom?` only says a row
  # EXISTS; `origin` says WHY. A runbook the phase-2 backfill materialized is
  # custom-but-inherited, and reporting it as diverged would have shown six false
  # divergences on day one — making the signal noise exactly when it first appears.
  #
  # jazari-agent's point is sharper than my original suggestion: comparing content
  # against the canon cannot separate them either, because a backfilled runbook
  # genuinely DIFFERS (it carries the app's hand-written steps). Provenance is the
  # only honest discriminator.
  test "a runbook materialized by the backfill is not reported as diverged" do
    target = FleetCanon.target_for(@app)
    resolved = Jazari.resolve(target: target)
    skip "needs jazari >= 0.3 (origin)" unless resolved.respond_to?(:diverged?)

    Jazari.customize(target: target, expected_revision: resolved.revision,
                     topic: "Backfilled", description: "from deploy_checklist_items",
                     checklist: [ { id: "one", text: "step" } ], origin: "migration")

    row = subject_row
    assert_equal "custom", row[:state], "the row exists, so the state is custom"
    refute row[:diverged], "it was materialized, not chosen — provenance says so"
    assert_equal "migration", row[:origin]
  end

  test "an operator's own edit is still reported as diverged" do
    target = FleetCanon.target_for(@app)
    resolved = Jazari.resolve(target: target)
    Jazari.customize(target: target, expected_revision: resolved.revision,
                     topic: "Operator's way", description: "mine", checklist: [ { id: "one", text: "step" } ])

    assert subject_row[:diverged], "no origin means a human chose this"
  end
end
