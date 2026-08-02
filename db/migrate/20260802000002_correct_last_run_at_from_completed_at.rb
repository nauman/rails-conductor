# last_run_at was only written when a backup FAILED, so every schedule that has
# been succeeding carries a last_run_at from its last bad night — or none at all,
# for one that has never failed. `overdue?` reads that column, so healthy
# backups were being reported stale.
#
# completed_at IS accurate on the success path, so it can repair the column for
# rows already in this state. GREATEST, not a blind copy: a backup whose most
# recent attempt FAILED has the newer last_run_at, and moving it backwards would
# hide a real failure behind an older success.
class CorrectLastRunAtFromCompletedAt < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE backups
         SET last_run_at = GREATEST(completed_at, COALESCE(last_run_at, completed_at))
       WHERE completed_at IS NOT NULL
         AND (last_run_at IS NULL OR last_run_at < completed_at)
    SQL
  end

  # Deliberately irreversible. The old values were wrong; restoring them would
  # mean deliberately re-introducing false "stale backup" alarms, and the
  # information needed to reconstruct them was never recorded anyway.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
