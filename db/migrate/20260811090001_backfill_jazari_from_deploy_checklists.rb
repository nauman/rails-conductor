# Phase 2 of the jazari adoption: move the live deploy checklists onto the gem.
#
# `deploy_checklist_items` is the pre-gem checklist — one flat table of per-app
# steps, with `done` and `done_at` on the item. jazari splits those two facts on
# purpose: `done` is CURRENT STATE and belongs to the runbook, timestamped
# completion is HISTORY and belongs to a run. Holding the same fact in both layers
# lets them disagree, so this writes each to exactly one place.
#
# Three things this migration will not do, each because it would destroy something:
#
#   1. It does not reset `done`. Operators are mid-procedure right now — at the
#      last census Calm.page was 3 of 12 and Starrrs 13 of 14. A migration that
#      restarts them erases that work with no trace and no complaint.
#   2. It does not translate item ids. Every existing id already satisfies
#      Jazari::Checklist::ID_FORMAT as a string, measured rather than assumed, so
#      ids quoted in deploy documentation keep resolving and no map is needed.
#   3. It does not drop or edit `deploy_checklist_items`. That is a later deploy,
#      after this one has been observed in production.
#
# It raises rather than fixing forward if the item count does not survive the
# move. A backfill that silently loses steps is worse than one that stops.
class BackfillJazariFromDeployChecklists < ActiveRecord::Migration[8.0]
  MIGRATION_ACTOR = "migration"

  # Its own transaction, rather than relying on the one the migration runner opens:
  # the census below is only a safety gate if a shortfall un-writes what it already
  # wrote. Depending on an enclosing transaction makes that guarantee something a
  # caller can remove without noticing.
  def up
    ActiveRecord::Base.transaction { backfill! }
  end

  def backfill!
    apps = App.left_joins(:deploy_checklist_items)
               .where("deploy_checklist_items.id IS NOT NULL OR (apps.deploy_runbook IS NOT NULL AND apps.deploy_runbook <> '')")
               .distinct

    moved = 0
    skipped = 0

    apps.find_each do |app|
      # Order by position and re-index by ARRAY ORDER: positions are assigned as
      # maximum + 1, so deletions leave gaps and position is not a dense index.
      items = app.deploy_checklist_items.order(:position, :id).to_a
      checklist = items.map do |item|
        { "id" => item.id.to_s, "text" => item.content.to_s,
          "done" => item.done == true, "required" => item.required != false }
      end

      recipe_id = FleetCanon.shape_for(app)[:recipe_id]
      runbook = Jazari::Runbook.find_or_initialize_by(runbookable_type: app.class.name, runbookable_id: app.id)
      if runbook.persisted?
        # Already moved, or an operator got here first. Never clobber a live
        # override — count it as accounted for so the census below still balances.
        skipped += checklist.length
        next
      end

      runbook.recipe_id   = recipe_id
      runbook.topic       = Jazari::RecipeRegistry.fetch(recipe_id).topic.presence || "Deploy"
      runbook.description = app.deploy_runbook.to_s
      runbook.checklist   = checklist
      runbook.save!

      moved += checklist.length

      backfill_run(app: app, recipe_id: recipe_id, checklist: checklist, items: items)
    end

    expected = DeployChecklistItem.count
    unless moved + skipped == expected
      raise "backfill lost items: moved #{moved} + skipped #{skipped}, expected #{expected}"
    end

    say "backfilled #{moved} checklist items (#{skipped} already present) across #{apps.count} apps"
  end

  def down
    Jazari::Run.where(actor_ref: MIGRATION_ACTOR).delete_all
    Jazari::Runbook.where(runbookable_type: "App").delete_all
  end

  private

  # A closed run per app, purely to preserve the `done_at` values the item schema
  # has no field for. `actor_ref` is honestly "migration" — inventing a user here
  # would put a name against work we cannot attribute.
  def backfill_run(app:, recipe_id:, checklist:, items:)
    stamped = items.select { |item| item.done? && item.done_at.present? }
    return if stamped.empty?

    started = stamped.map(&:done_at).min.utc
    finished = stamped.map(&:done_at).max.utc

    ticks = stamped.map do |item|
      { "id" => item.id.to_s, "done" => true, "at" => item.done_at.utc.iso8601,
        "actor_ref" => MIGRATION_ACTOR, "note" => nil }
    end

    # Outcome from the REQUIRED items only: an optional step left undone does not
    # make a completed procedure incomplete.
    required = checklist.select { |item| item["required"] }
    outcome = required.all? { |item| item["done"] } ? "completed" : "abandoned"

    Jazari::Run.create!(
      recipe_id: recipe_id,
      subject_type: app.class.name,
      subject_id: app.id,
      actor_ref: MIGRATION_ACTOR,
      checklist_snapshot: checklist,
      ticks: ticks,
      evidence: [],
      idempotency_policy: Jazari::RunPolicy::UNRESTRICTED,
      source_digest: Jazari::RecipeRegistry.fetch(recipe_id).digest,
      started_at: started,
      started_on: started.to_date,
      finished_at: finished,
      outcome: outcome
    )
  end
end
