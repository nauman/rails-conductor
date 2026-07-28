require "test_helper"

# Spec 08, slice 1 (UI half). The dashboard raised a critical incident for EVERY failed
# deployment in the last 24 hours, so an app that failed twice and then deployed cleanly
# still showed two incidents. Operator: "our failures flag doesn't resolve — it feels so
# many even when they get resolved." An incident list that never clears gets ignored.
class DashboardIncidentsTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "dash@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @org.update!(onboarded_at: Time.current)
    sign_in_as @user
  end

  def sign_in_as(user)
    session_record = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{session_record.to_param}/#{session_record.token}"
  end

  def app_with(*statuses)
    app = @org.apps.create!(name: "App#{SecureRandom.hex(3)}", slug: "app-#{SecureRandom.hex(3)}")
    statuses.each_with_index do |status, i|
      app.deployments.create!(user: @user, status: status, created_at: (statuses.size - i).hours.ago)
    end
    app
  end

  # Asserted on what actually renders, not controller internals: the incident row
  # carries data-incident-resource="<app> deployment".
  def deployment_incidents_for(app)
    css_select(%(*[data-incident-resource="#{app.name} deployment"]))
  end

  test "a failure that a later deploy fixed raises no incident" do
    app = app_with("failed", "failed", "succeeded")

    get dashboard_path
    assert_response :success
    assert_empty deployment_incidents_for(app),
                 "three deploys, two failed, last one green — nothing to act on"
  end

  test "an app whose latest deploy failed raises exactly one incident" do
    app = app_with("failed", "succeeded", "failed")

    get dashboard_path
    assert_equal 1, deployment_incidents_for(app).size,
                 "one broken app is one incident, not one per failure"
  end

  test "an in-flight deploy after a failure is not yet an incident" do
    app = app_with("failed", "deploying")

    get dashboard_path
    assert_empty deployment_incidents_for(app), "it is being fixed right now"
  end

  test "the incident says when the failure was not the app's fault" do
    app = app_with("succeeded")
    app.deployments.create!(user: @user, status: "failed", cause_class: "infrastructure",
                            created_at: 1.minute.ago)

    get dashboard_path
    assert_equal 1, deployment_incidents_for(app).size
    assert_match(/infrastructure/i, response.body)
  end

  test "a blocked deploy is an incident — it never ran" do
    app = app_with("blocked")

    get dashboard_path
    assert_equal 1, deployment_incidents_for(app).size
    assert_match(/refused by preflight/i, response.body)
  end

  # The panel used to list the last 10 DEPLOYMENTS, so one app that failed twice and then
  # shipped cleanly took three rows and read as three problems. The fleet shows state.
  test "the apps panel shows one row per app, whatever its deploy history" do
    app = app_with("failed", "failed", "succeeded")

    get dashboard_path
    assert_equal 1, css_select(%(*[data-app-row="#{app.slug}"])).size
    assert_match(/deployed/, css_select(%(*[data-app-row="#{app.slug}"])).first.text)
  end

  test "an app that never deployed here says so rather than looking healthy" do
    app = @org.apps.create!(name: "Untouched", slug: "untouched-#{SecureRandom.hex(2)}")

    get dashboard_path
    row = css_select(%(*[data-app-row="#{app.slug}"])).first
    assert row, "an app with no deploys still belongs on the fleet"
    assert_match(/not deployed here/i, row.text)
  end

  test "a failure that was not the app's fault is labelled" do
    app = app_with("succeeded")
    app.deployments.create!(user: @user, status: "failed", cause_class: "infrastructure",
                            created_at: 1.minute.ago)

    get dashboard_path
    assert_match(/not app code/i, css_select(%(*[data-app-row="#{app.slug}"])).first.text)
  end

  test "apps needing a decision are listed before healthy ones" do
    healthy = app_with("succeeded")
    broken = app_with("failed")

    get dashboard_path
    rows = css_select("*[data-app-row]").map { |r| r["data-app-row"] }
    assert_operator rows.index(broken.slug), :<, rows.index(healthy.slug),
                    "the broken app should not be below the healthy one"
  end
end
