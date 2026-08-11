# The provenance that 20260811090001 was supposed to write, and didn't.
#
# That migration first landed WITHOUT `origin`, ran on a deploy, and created the six
# App runbooks. When it was later improved to set `origin = "migration"`, its version
# was already in `schema_migrations`, so the improved code never executed — editing an
# already-run migration changes nothing. The rows exist, created by the version that
# predated provenance.
#
# Two things are wrong in production because of it, both verified rather than assumed:
#
#   1. `Jazari::ResolvedRunbook#diverged?` is `custom? && origin.nil?`, so all six apps
#      report as deliberate operator divergences. That is the exact noise both sides
#      wrote code to prevent, and it makes the signal useless the day it appears.
#   2. `20260811090001#down` deletes `where(origin: "migration")`, which matches zero
#      rows — the rollback path is inert.
#
# Identification is by CONTENT, not by trust. A row is the backfill's work only if its
# checklist item ids are exactly the app's `deploy_checklist_items` ids. An operator's
# own runbook cannot coincidentally carry that id set, and a row already carrying an
# origin is never touched. `origin IS NULL` alone would not be enough: a human using
# `Jazari.customize` without an origin also leaves it null.
#
# update_columns on purpose: bumping `lock_version` would invalidate revisions held
# right now by agents mid-checklist, and `updated_at` should not claim the procedure
# changed when only its provenance was recorded.
class BackfillJazariRunbookOrigin < ActiveRecord::Migration[8.1]
  MIGRATION_ACTOR = "migration"

  def up
    stamped = 0

    Jazari::Runbook.where(runbookable_type: "App", origin: nil).find_each do |runbook|
      item_ids = Array(runbook.checklist).map { |item| item["id"].to_s }.sort
      next if item_ids.empty?

      legacy_ids = DeployChecklistItem.where(app_id: runbook.runbookable_id).pluck(:id).map(&:to_s).sort
      next if legacy_ids.empty? || item_ids != legacy_ids

      runbook.update_columns(origin: MIGRATION_ACTOR)
      stamped += 1
    end

    say "stamped #{stamped} backfilled runbook(s) with origin=#{MIGRATION_ACTOR}"
  end

  def down
    # Only what this migration set. A row an operator has since made their own will
    # have had its origin cleared by jazari already, so it is not matched here.
    Jazari::Runbook.where(runbookable_type: "App", origin: MIGRATION_ACTOR)
                   .update_all(origin: nil)
  end
end
