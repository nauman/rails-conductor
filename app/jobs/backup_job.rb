class BackupJob < ApplicationJob
  queue_as :default

  def perform(backup_id)
    backup = Backup.find(backup_id)
    service = DatabaseBackup.new(backup)
    service.run!
  end
end
