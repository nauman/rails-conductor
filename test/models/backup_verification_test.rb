require "test_helper"

# Design B2: the status that matters is not "the dump uploaded", it is "we put it back and
# the data was there". A file in a bucket is a hope, not a backup — so the model has to be
# able to say which of the two it has.
class BackupVerificationTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ver@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @subject = @org.apps.create!(name: "Appone", slug: "appone")
    @backup = @org.backups.create!(app: @subject, provider: "cloudflare_r2",
                                   bucket_name: "acme-backups", schedule: "daily",
                                   retention_days: 14, enabled: true)
  end

  test "a backup that has run but never been restored is unverified, not healthy" do
    @backup.update!(last_run_at: 1.hour.ago, status: "completed")

    assert_equal :unverified, @backup.verification_state
    refute @backup.proven?, "nobody has restored it — that is a hope, not a backup"
  end

  test "a backup that has never run says so" do
    assert_equal :never_run, @backup.verification_state
  end

  test "a proved restore is the only state that counts as safe" do
    @backup.update!(last_run_at: 2.hours.ago, status: "completed",
                    verification_status: "verified", verified_at: 1.hour.ago,
                    verification_note: "restored to scratch db; 14 tables, row counts matched")

    assert_equal :verified, @backup.verification_state
    assert @backup.proven?
  end

  test "a failed restore is the loudest state on the page" do
    @backup.update!(last_run_at: 2.hours.ago, status: "completed",
                    verification_status: "failed", verification_note: "relation missing")

    assert_equal :restore_failed, @backup.verification_state
    refute @backup.proven?
    assert @backup.alarming?, "a dump that exists and doesn't work is worse than none"
  end

  test "a stale schedule beats a stale verification" do
    @backup.update!(last_run_at: 6.days.ago, status: "completed",
                    verification_status: "verified", verified_at: 6.days.ago)

    assert_equal :stale, @backup.verification_state,
                 "the schedule says nightly and reality disagrees — say that first"
  end
end
