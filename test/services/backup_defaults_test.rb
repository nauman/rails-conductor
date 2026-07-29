require "test_helper"

# Design B1: 0 of 12 apps had a backup, not through carelessness but because turning one on
# asked for a provider, a bucket, a credential and a schedule — per app. The fix is not a
# better form; it is not asking. Everything here is a default the operator can change later.
class BackupDefaultsTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "bk@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cf = @org.credentials.create!(name: "R2", provider: "cloudflare", api_key: "tok",
                                   account_id: "acct1", verified_at: Time.current)
    @subject = @org.apps.create!(name: "Appone", slug: "appone")
  end

  test "an app can be protected without answering a single question" do
    backup = BackupDefaults.new(@subject).build

    assert backup.valid?, backup.errors.full_messages.join(", ")
    assert_equal "daily", backup.schedule
    assert_equal 14, backup.retention_days
    assert backup.enabled?
    assert_equal @cf, backup.credential, "inherits the storage credential already connected"
    assert_equal @org, backup.organization
  end

  test "it refuses rather than inventing a destination when nothing is connected" do
    @cf.destroy
    assert_nil BackupDefaults.new(@subject).build,
               "a backup pointed at a bucket we made up is worse than no backup"
  end

  test "an unverified credential is not a destination" do
    @cf.update_columns(verified_at: nil)
    assert_nil BackupDefaults.new(@subject).build
  end

  test "parked apps are never protected automatically" do
    @subject.update!(intent: "placeholder")
    assert_nil BackupDefaults.new(@subject).build, "you already decided this one doesn't matter"
  end
end
