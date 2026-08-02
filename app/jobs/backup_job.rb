class BackupJob < ApplicationJob
  queue_as :default

  # run_id is optional so jobs already enqueued under the previous signature
  # still execute after a deploy; DatabaseBackup opens its own run when it is
  # missing, so history is recorded either way.
  def perform(backup_id, run_id = nil)
    backup = Backup.find(backup_id)
    run = run_id && BackupRun.find_by(id: run_id)
    DatabaseBackup.new(backup, run: run).run!
  end
end
