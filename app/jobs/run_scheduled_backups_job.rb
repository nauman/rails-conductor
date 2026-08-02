class RunScheduledBackupsJob < ApplicationJob
  queue_as :ops

  # Dispatches due backups. Runs every minute, so it must be careful about what
  # "due" means: a backup whose process died stays "running" with next_run_at in
  # the past, and re-enqueueing it every minute exhausted SSH on the box and
  # failed every OTHER backup with "connection closed by remote host". One stuck
  # backup took down all of them.
  def perform
    reap_stuck_runs
    dispatch_due
  end

  private

  # Release runs whose process died, so they stop blocking their own schedule.
  def reap_stuck_runs
    Backup.stuck.find_each do |backup|
      Rails.logger.warn(
        "[ScheduledBackup] backup #{backup.id} stuck in 'running' since " \
        "#{backup.last_run_at || 'unknown'} — reaping so it can be rescheduled"
      )
      backup.reap_stuck!
    end
  end

  def dispatch_due
    Backup.due.find_each do |backup|
      # Claim it BEFORE enqueueing. If the job dies, the schedule has already
      # moved on, so the worst case is one missed run — not a re-run every
      # minute until someone notices.
      backup.calculate_next_run
      # Recorded before the enqueue. If the job never reaches a worker, this row
      # stays at "dispatched" and BackupRun.lost finds it — otherwise a lost job
      # leaves nothing behind, because a run that never starts never fails.
      run = backup.record_dispatch!(trigger: "scheduled")
      Rails.logger.info "[ScheduledBackup] Running backup #{backup.id}: #{backup.bucket_name}"
      BackupJob.perform_later(backup.id, run.id)
    end
  end
end
