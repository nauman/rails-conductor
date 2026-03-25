class RunScheduledBackupsJob < ApplicationJob
  queue_as :ops

  def perform
    Backup.due.find_each do |backup|
      Rails.logger.info "[ScheduledBackup] Running backup #{backup.id}: #{backup.bucket_name}"
      BackupJob.perform_later(backup.id)
    end
  end
end
