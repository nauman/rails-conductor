require "test_helper"

# A backup whose process died stayed "running" with next_run_at in the past, so
# the every-minute dispatcher re-enqueued it forever. That stampede exhausted
# SSH on the box and failed every OTHER backup with "connection closed by remote
# host" — one stuck backup took the whole fleet's backups down.
class RunScheduledBackupsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @credential = @org.credentials.create!(name: "r2", provider: "cloudflare",
                                           api_key: "k", api_secret: "s")
  end

  def backup(status:, next_run_at:, last_run_at: nil)
    b = Backup.create!(organization: @org, server: @server, credential: @credential,
                       provider: "cloudflare_r2", bucket_name: "b", schedule: "daily",
                       enabled: true)
    # update_columns: the model recalculates next_run_at on save, which would
    # overwrite the very state under test.
    b.update_columns(status: status, next_run_at: next_run_at, last_run_at: last_run_at)
    b.reload
  end

  test "a due backup is dispatched" do
    b = backup(status: "completed", next_run_at: 1.minute.ago)

    assert_enqueued_with(job: BackupJob, args: ->(args) { args.first == b.id }) do
      RunScheduledBackupsJob.perform_now
    end
  end

  # The dispatch is recorded before the enqueue, so a job that never reaches a
  # worker still leaves a row. Without it, a lost job is invisible: it never
  # starts, so it never fails either.
  test "the dispatch is written to history, and the job carries that run's id" do
    b = backup(status: "completed", next_run_at: 1.minute.ago)

    assert_difference "BackupRun.count", 1 do
      RunScheduledBackupsJob.perform_now
    end

    run = b.runs.last
    assert_equal "dispatched", run.status
    assert_equal "scheduled", run.trigger
    assert_enqueued_with(job: BackupJob, args: [ b.id, run.id ])
  end

  # The stampede.
  test "a backup already running is NOT re-dispatched" do
    backup(status: "running", next_run_at: 1.day.ago, last_run_at: 1.minute.ago)

    assert_no_enqueued_jobs(only: BackupJob) { RunScheduledBackupsJob.perform_now }
  end

  test "the schedule is claimed BEFORE the job runs, so a crash cannot cause a re-run storm" do
    b = backup(status: "completed", next_run_at: 1.minute.ago)

    RunScheduledBackupsJob.perform_now

    assert b.reload.next_run_at > Time.current,
           "next_run_at must move forward at dispatch, not only on completion"
  end

  test "a run stuck past the threshold is reaped and rescheduled" do
    b = backup(status: "running", next_run_at: 1.day.ago,
               last_run_at: (Backup::STUCK_AFTER + 5.minutes).ago)

    RunScheduledBackupsJob.perform_now
    b.reload

    assert_equal "failed", b.status, "a died run is a failure, not a silent reset"
    assert b.next_run_at > Time.current, "reaping must release the schedule"
  end

  test "a recently-started run is left alone" do
    b = backup(status: "running", next_run_at: 1.day.ago, last_run_at: 1.minute.ago)

    RunScheduledBackupsJob.perform_now

    assert_equal "running", b.reload.status, "a legitimately in-flight backup must not be reaped"
  end

  # The whole point: one stuck backup must not starve the others.
  test "a stuck backup does not prevent other backups from running" do
    backup(status: "running", next_run_at: 1.day.ago, last_run_at: 2.days.ago)
    healthy = backup(status: "completed", next_run_at: 1.minute.ago)

    assert_enqueued_with(job: BackupJob, args: ->(args) { args.first == healthy.id }) do
      RunScheduledBackupsJob.perform_now
    end
  end

  test "a disabled backup is never dispatched or reaped" do
    b = backup(status: "running", next_run_at: 1.day.ago, last_run_at: 2.days.ago)
    b.update_columns(enabled: false)

    assert_no_enqueued_jobs(only: BackupJob) { RunScheduledBackupsJob.perform_now }
    assert_equal "running", b.reload.status
  end
end
