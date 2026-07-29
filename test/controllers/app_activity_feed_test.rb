require "test_helper"

# The app page is where you go for history (operator's Q3: history, logs, runbook, config).
# It used to be a status table; it's now a feed that says what happened and WHY.
class AppActivityFeedTest < ActionDispatch::IntegrationTest
  # NB: the record is @subject, not @app — ActionDispatch::IntegrationTest stores the Rack
  # application in @app, and overwriting it makes every `get` call App#call.
  setup do
    @user = User.create!(email: "feed@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @org.update!(onboarded_at: Time.current)
    @subject = @org.apps.create!(name: "Appone", slug: "appone")
    session_record = Passwordless::Session.create!(authenticatable: @user)
    get "/users/sign_in/#{session_record.to_param}/#{session_record.token}"
  end

  test "a failure that wasn't the app's code says so" do
    @subject.deployments.create!(user: @user, status: "failed", cause_class: "infrastructure",
                             commit_sha: "abc1234567")

    get app_path(@subject)
    assert_response :success
    assert_match(/Infrastructure, not app code/i, response.body)
  end

  test "an unclassified failure stays silent rather than blaming the app" do
    @subject.deployments.create!(user: @user, status: "failed", commit_sha: "def1234567")

    get app_path(@subject)
    assert_match(/Deploy failed/, response.body)
    refute_match(/failed to build, migrate, or boot/i, response.body,
                 "we don't know the cause — don't invent one")
  end

  test "a forced deploy is visible after the fact" do
    @subject.deployments.create!(user: @user, status: "succeeded", forced: true, commit_sha: "aaa1111111")

    get app_path(@subject)
    assert_match(/forced past preflight/i, response.body)
  end

  test "a blocked deploy says it never ran" do
    @subject.deployments.create!(user: @user, status: "blocked")

    get app_path(@subject)
    assert_match(/refused by preflight/i, response.body)
  end

  test "an app with no deploys explains itself instead of showing an empty table" do
    @subject.update!(intent: "pending_migration", intent_note: "becomes a calm.page Liquid theme")

    get app_path(@subject)
    assert_match(/Nothing has deployed through Conductor yet/i, response.body)
    assert_match(/becomes a calm.page Liquid theme/, response.body)
  end
end
