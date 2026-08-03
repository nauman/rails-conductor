require "test_helper"

class VerifyBackupRestoreJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    user = User.create!(email: "vj@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare", api_key: "k", api_secret: "s")
  end

  def backup(verified_at:, enabled: true, credential: :default)
    @org.backups.create!(provider: "cloudflare_r2", bucket_name: "test-bucket",
                         credential: (credential == :default ? @cred : credential),
                         server: @server, schedule: "daily", enabled: enabled)
       .tap { |b| b.update_columns(verified_at: verified_at) }
  end

  # One per night, not ten: each restore pulls a full dump and starts a postgres
  # container. Verifying the whole fleet at once is the stampede shape that took
  # the backups down on 2026-08-01.
  test "the sweep enqueues exactly one verification" do
    3.times { |i| backup(verified_at: i.days.ago) }

    assert_enqueued_jobs 1, only: VerifyBackupRestoreJob do
      VerifyBackupRestoreJob.sweep
    end
  end

  test "a never-verified backup goes before one verified long ago" do
    backup(verified_at: 30.days.ago)
    never = backup(verified_at: nil)

    assert_equal never.id, VerifyBackupRestoreJob.sweep.id,
                 "never_tested is a worse state than stale — it must go first"
  end

  test "the stalest verified backup is chosen when all have been tested" do
    backup(verified_at: 2.days.ago)
    oldest = backup(verified_at: 40.days.ago)

    assert_equal oldest.id, VerifyBackupRestoreJob.sweep.id
  end

  test "disabled backups are never verified" do
    backup(verified_at: nil, enabled: false)

    assert_nil VerifyBackupRestoreJob.sweep
    assert_no_enqueued_jobs(only: VerifyBackupRestoreJob) { VerifyBackupRestoreJob.sweep }
  end

  test "a backup with no credential cannot be fetched, so it is not attempted" do
    b = backup(verified_at: nil)
    b.update_columns(credential_id: nil)

    assert_nil VerifyBackupRestoreJob.sweep
  end

  test "an empty fleet is a no-op, not an error" do
    assert_nothing_raised { assert_nil VerifyBackupRestoreJob.sweep }
  end
end
