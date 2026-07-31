# Corrects data written by 20260731000003, which ran in production before its
# backfill was reviewed.
#
# That migration stamped EVERY historical deployment with its app's CURRENT
# deploy_method — which destroys the distinction the column exists to make. For
# an app moved kamal → docker, every Kamal-era release is now labelled "docker"
# and is therefore offered as a rollback target naming an image that does not
# exist on the host.
#
# The honest value for a release whose runtime cannot be reconstructed is NULL:
# `Deployment#compatible_runtime?` treats NULL as unknown and excludes it. A
# smaller, honest set of rollback targets beats a larger, wrong one.
#
# Only apps that have actually changed form are touched. An app that has always
# been in its current shape was stamped correctly by accident, and there is no
# reason to discard that.
class CorrectInventedDeploymentRuntimes < ActiveRecord::Migration[8.0]
  # Batched so each chunk commits on its own rather than holding row locks for
  # the whole table. That REQUIRES running outside a transaction — which is the
  # only reason this is disabled here, and why it is a separate migration from
  # the schema change it corrects.
  disable_ddl_transaction!

  BATCH = 5_000

  def up
    say_with_time "clearing invented runtimes on apps that have changed form" do
      total = 0
      loop do
        cleared = execute(<<~SQL).cmd_tuples
          UPDATE deployments
          SET deploy_method = NULL, infra_revision = NULL
          WHERE id IN (
            SELECT d.id
            FROM deployments d
            WHERE d.deploy_method IS NOT NULL
              AND EXISTS (
                SELECT 1 FROM infra_revisions r
                WHERE r.app_id = d.app_id AND r.changes_made ? 'deploy_method'
              )
            LIMIT #{BATCH}
          )
        SQL
        total += cleared.to_i
        break if cleared.to_i.zero?
      end
      total
    end
  end

  # Irreversible by design: the values being cleared were never real, so there is
  # nothing to restore. Re-running 20260731000003's backfill would only reinvent
  # them.
  def down
    raise ActiveRecord::IrreversibleMigration,
          "the cleared values were invented, not observed — there is nothing to restore"
  end
end
