require "test_helper"

# Per-attempt backup history.
#
# The `backups` row holds only the LATEST state, so a run that was dispatched
# and never executed left no trace anywhere — the question "did Calm.page back
# up on the 31st?" was unanswerable after the fact. A dispatched-but-never-
# finished row is exactly the evidence that was missing.
class BackupRunTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "runs@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare", api_key: "k", api_secret: "s")
    @backup = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "b",
                                   credential: @cred, server: @server,
                                   schedule: "daily", enabled: true)
  end

  test "a dispatch is recorded before anything runs" do
    run = @backup.record_dispatch!(trigger: "scheduled")

    assert_equal "dispatched", run.status
    assert_equal "scheduled", run.trigger
    assert run.dispatched_at.present?
    assert_nil run.started_at, "nothing has started yet"
  end

  test "starting a run stamps started_at and moves it out of dispatched" do
    run = @backup.record_dispatch!(trigger: "scheduled")
    run.start!

    assert_equal "running", run.reload.status
    assert run.started_at.present?
  end

  test "completing records the size that was actually uploaded" do
    run = @backup.record_dispatch!(trigger: "manual")
    run.start!
    run.complete!(size_bytes: 4_096)

    run.reload
    assert_equal "completed", run.status
    assert_equal 4_096, run.size_bytes
    assert run.finished_at.present?
    assert_nil run.error_message
  end

  test "failing keeps the reason — a failure with no reason is not evidence" do
    run = @backup.record_dispatch!(trigger: "scheduled")
    run.start!
    run.fail!("Database dump failed: connection closed by remote host")

    run.reload
    assert_equal "failed", run.status
    assert_match "connection closed", run.error_message
    assert run.finished_at.present?
  end

  # THE point of the table. A job that is enqueued and then lost never starts,
  # so it never fails either — it simply leaves no record at all today.
  test "a dispatch that never started is findable as lost" do
    lost = @backup.record_dispatch!(trigger: "scheduled")
    lost.update_columns(dispatched_at: (BackupRun::LOST_AFTER + 10.minutes).ago)

    assert_includes BackupRun.lost, lost
  end

  test "a dispatch still within its grace period is not called lost" do
    fresh = @backup.record_dispatch!(trigger: "scheduled")

    assert_not_includes BackupRun.lost, fresh
  end

  test "a run that started is never 'lost', however long it takes" do
    run = @backup.record_dispatch!(trigger: "scheduled")
    run.update_columns(dispatched_at: (BackupRun::LOST_AFTER + 10.minutes).ago)
    run.start!

    assert_not_includes BackupRun.lost, run,
                        "it started — whether it is slow or stuck is a different question"
  end

  test "runs read newest first" do
    old = @backup.record_dispatch!(trigger: "scheduled")
    old.update_columns(dispatched_at: 2.days.ago)
    recent = @backup.record_dispatch!(trigger: "manual")

    assert_equal [ recent.id, old.id ], @backup.runs.recent.limit(2).map(&:id)
  end

  test "history survives independently of the backup's current state" do
    @backup.record_dispatch!(trigger: "scheduled").tap { |r| r.start!; r.fail!("boom") }
    @backup.record_dispatch!(trigger: "scheduled").tap { |r| r.start!; r.complete!(size_bytes: 10) }

    assert_equal %w[completed failed], @backup.runs.recent.map(&:status)
  end

  test "deleting a backup takes its history with it" do
    @backup.record_dispatch!(trigger: "scheduled")

    assert_difference "BackupRun.count", -1 do
      @backup.destroy
    end
  end
end
