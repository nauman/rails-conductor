require "test_helper"

# intellectaco's backup read `completed` in production while its dump restored
# to ZERO tables. The verifier knew — `verification_status: "failed"` — and the
# status field beside it still said the backup had succeeded.
#
# That is the same shape as the upload bug: a row asserting success next to
# evidence of failure. The evidence has to win, because `status` is what the
# list, the coverage count and the operator's glance all read.
class BackupVerificationGatingTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "gate@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @backup = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "buck",
                                   server: @server, schedule: "daily", enabled: true)
    @backup.update_columns(status: "completed", last_run_at: Time.current, size_bytes: 1032)
  end

  test "a restore that produces no tables demotes the backup from completed" do
    @backup.record_restore_failure!("restore produced no tables — the dump is not a usable backup")

    assert_equal "failed", @backup.reload.status,
                 "a dump that cannot restore is not a completed backup"
    assert_equal "failed", @backup.verification_status
    assert_match(/no tables/, @backup.verification_note)
  end

  test "a successful restore keeps the backup completed and records the evidence" do
    @backup.record_restore_success!(note: "restored into a clean postgres: 44 tables, ~27360 rows")

    assert_equal "completed", @backup.reload.status
    assert_equal "verified", @backup.verification_status
    assert @backup.proven?
  end

  # Verification runs long after the upload. If a newer run has since succeeded,
  # an old dump's failed restore must not overwrite the fresh result — the
  # demotion is about THIS dump, not about the backup forever.
  test "a failed restore does not demote a backup that has run again since" do
    @backup.update_columns(status: "completed", last_run_at: Time.current)
    verified_at = 2.hours.ago

    @backup.record_restore_failure!("stale dump", checked_at: verified_at)

    assert_equal "completed", @backup.reload.status,
                 "the verified dump is older than the current run — do not demote"
  end

  test "demotion is visible as an alarm, not just a status" do
    @backup.record_restore_failure!("restore produced no tables")

    assert @backup.reload.alarming?
    refute @backup.proven?
  end
end
