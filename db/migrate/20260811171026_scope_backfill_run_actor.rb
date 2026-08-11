# The rollback hazard codex's audit found: 20260811090001 wrote runs with
# `actor_ref: "migration"` and its `down` deleted EVERY run carrying that value. The
# string is reusable — a later migration, or any system process choosing it, would
# have its runs deleted by an unrelated rollback.
#
# That migration now writes a version-scoped actor, and its `down` is narrowed. This
# repairs the rows already written: `up` cannot re-run (its version is recorded), but
# rows written by the first version are still in production carrying the bare value.
#
# Only runs whose subject is an App this backfill created are touched, identified
# through the runbook's `origin` rather than by trusting the actor string alone.
class ScopeBackfillRunActor < ActiveRecord::Migration[8.1]
  SCOPED = "migration:20260811090001".freeze
  LEGACY = "migration".freeze

  def up
    backfilled = Jazari::Runbook.where(runbookable_type: "App", origin: [ LEGACY, SCOPED ])

    updated = Jazari::Run.where(actor_ref: LEGACY, subject_type: "App",
                                subject_id: backfilled.select(:runbookable_id))
                         .update_all(actor_ref: SCOPED)

    # Same reasoning for the runbook marker, so `origin` and `actor_ref` agree.
    stamped = Jazari::Runbook.where(runbookable_type: "App", origin: LEGACY).update_all(origin: SCOPED)

    say "scoped #{updated} run(s) and #{stamped} runbook marker(s) to #{SCOPED}"
  end

  def down
    Jazari::Run.where(actor_ref: SCOPED).update_all(actor_ref: LEGACY)
    Jazari::Runbook.where(runbookable_type: "App", origin: SCOPED).update_all(origin: LEGACY)
  end
end
