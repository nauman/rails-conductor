# ADR 0004 describes InfraRevision as one row per shape an app has been in, but
# the column migration created none for existing apps — so every app claimed
# revision 1 with no history explaining what that shape is.
#
# Backfills a revision-1 row per app, recording the shape it was in when the
# model was introduced. Descriptive rather than a real transition, and marked as
# such, so nobody reads it as "this app changed form on 2026-07-31".
class BackfillInfraRevisionOne < ActiveRecord::Migration[8.0]
  def up
    say_with_time "backfilling infra_revision 1 history" do
      execute(<<~SQL)
        INSERT INTO infra_revisions (app_id, revision, changes_made, reason, created_at, updated_at)
        SELECT a.id,
               1,
               jsonb_build_object(
                 'server_id',          jsonb_build_array(NULL, a.server_id),
                 'deploy_method',      jsonb_build_array(NULL, a.deploy_method),
                 'database_mode',      jsonb_build_array(NULL, a.database_mode),
                 'database_placement', jsonb_build_array(NULL, a.database_placement)
               ),
               'baseline: shape recorded when infrastructure revisions were introduced',
               NOW(), NOW()
        FROM apps a
        WHERE NOT EXISTS (
          SELECT 1 FROM infra_revisions r WHERE r.app_id = a.id AND r.revision = 1
        )
      SQL
    end
  end

  def down
    execute("DELETE FROM infra_revisions WHERE revision = 1 AND reason LIKE 'baseline:%'")
  end
end
