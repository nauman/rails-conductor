require "test_helper"

# `last_run_at` was only ever written when a backup FAILED. DatabaseBackup's
# success path set status/size/completed_at and nothing else, and the one method
# that did set it — Backup#mark_completed! — had no callers.
#
# The consequences were not cosmetic:
#   * `overdue?` reads last_run_at, so a backup that succeeds every night looks
#     progressively more stale. Two healthy apps were flagged STALE while their
#     dumps were landing in the bucket.
#   * `Backup.stuck` reads last_run_at too, so a run whose last_run_at was null
#     or old matched the stuck scope the instant it started, letting the reaper
#     mark a live, healthy run as failed.
#
# So it is stamped when the run STARTS. That is the honest meaning of "when did
# this last run", it is what stuck-detection needs to measure from, and it no
# longer depends on the outcome.
class BackupLastRunAtTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "lra@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare", api_key: "k", api_secret: "s")
    @backup = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "test-bucket",
                                   credential: @cred, server: @server,
                                   schedule: "daily", enabled: true)
    @backup.update_columns(last_run_at: 5.days.ago)
  end

  test "beginning a run stamps last_run_at, whatever the outcome turns out to be" do
    @backup.begin_run!

    assert_equal "running", @backup.reload.status
    assert @backup.last_run_at > 1.minute.ago
  end

  test "a SUCCESSFUL backup leaves last_run_at current" do
    @backup.begin_run!
    @backup.mark_completed!(size_bytes: 2_048)

    @backup.reload
    assert_equal "completed", @backup.status
    assert_equal 2_048, @backup.size_bytes
    assert @backup.last_run_at > 1.minute.ago,
           "success must advance last_run_at — this was the bug"
    assert @backup.completed_at.present?
  end

  test "a backup succeeding on schedule is never reported overdue" do
    @backup.begin_run!
    @backup.mark_completed!(size_bytes: 2_048)

    assert_not @backup.reload.overdue?,
               "a daily backup that just succeeded cannot be stale"
    assert_equal :unverified, @backup.verification_state
  end

  # The inversion that produced the false alarm: before the fix, only failures
  # moved last_run_at, so the more reliably a backup worked the staler it looked.
  test "a backup that has genuinely not run in days is still reported overdue" do
    assert @backup.overdue?, "5 days without a run on a daily schedule is stale"
  end

  test "a live run is not mistaken for a stuck one" do
    @backup.begin_run!

    assert_not_includes Backup.stuck, @backup,
                        "it started seconds ago — the reaper must leave it alone"
  end

  test "a run whose process died is still reaped" do
    @backup.begin_run!
    @backup.update_columns(last_run_at: (Backup::STUCK_AFTER + 5.minutes).ago)

    assert_includes Backup.stuck, @backup
  end
end
