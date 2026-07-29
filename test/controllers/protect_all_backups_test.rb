require "test_helper"

# Design B1/B3/B5: one button protects the fleet, parked apps are left alone, and an
# unprotected app appears in the language the dashboard already speaks.
class ProtectAllBackupsTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "protect@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @org.update!(onboarded_at: Time.current)
    @org.credentials.create!(name: "R2", provider: "cloudflare", api_key: "tok",
                             account_id: "a1", verified_at: Time.current)
    @managed = @org.apps.create!(name: "Managed", slug: "managed")
    @parked = @org.apps.create!(name: "Parked", slug: "parked", intent: "pending_migration")
    @placeholder = @org.apps.create!(name: "Ph", slug: "ph", intent: "placeholder")
    session_record = Passwordless::Session.create!(authenticatable: @user)
    get "/users/sign_in/#{session_record.to_param}/#{session_record.token}"
  end

  test "one button protects every app that should be protected" do
    assert_difference -> { Backup.count }, 1 do
      post protect_all_backups_path
    end

    assert_redirected_to backups_path
    assert @managed.reload.backups.any?, "a managed app gets protected"
    assert_empty @parked.reload.backups, "awaiting a calm.page theme — you already decided"
    assert_empty @placeholder.reload.backups
  end

  test "running it twice does not double-protect" do
    post protect_all_backups_path
    assert_no_difference -> { Backup.count } do
      post protect_all_backups_path
    end
  end

  test "an unprotected app raises one warning in the dashboard's own language" do
    get dashboard_path
    assert_match(/no backup/i, response.body)
  end

  test "the warning clears once protected" do
    post protect_all_backups_path
    get dashboard_path
    refute_match(/1 app has no backup/i, response.body)
  end
end
