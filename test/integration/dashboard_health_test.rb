require "test_helper"

class DashboardHealthTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "dashboard-health@example.com")
    @org = Organization.create_for(@user, name: "Dashboard Health")
    @org.update!(onboarded_at: Time.current)
    key = SshKey.create!(name: "dashboard-key", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "dashboard-host", status: "online", ip_address: "10.0.0.20",
                                   ssh_key: key, ssh_user: "deploy", last_seen_at: Time.current)
    sign_in_as(@user)
  end

  test "intentionally stopped app is omitted while running mismatch appears once" do
    create_app(name: "Expected stopped", status: "stopped", container_status: "exited")
    create_app(name: "Unexpected stop", status: "running", container_status: "exited")

    get dashboard_path

    assert_response :success
    assert_select "[data-incident-resource='Unexpected stop']", count: 1
    assert_select "[data-incident-resource='Expected stopped']", count: 0
    assert_includes response.body, "Expected running, observed exited"
  end

  test "stopped app observed running is one actionable incident" do
    create_app(name: "Still running", status: "stopped", container_status: "running")

    get dashboard_path

    assert_select "[data-incident-resource='Still running']", count: 1
    assert_includes response.body, "Running unexpectedly"
  end

  test "monitoring uncertainty never claims an app is stopped" do
    create_app(name: "Stale app", container_status: "running", last_status_check_at: 10.minutes.ago)
    create_app(name: "Failed check", container_status: "running", status_check_error: "permission denied")

    get dashboard_path

    assert_includes response.body, "Container status is stale"
    assert_includes response.body, "Status check failed"
    assert_no_match(/Stale app.*App is stopped/m, response.body)
    assert_no_match(/Failed check.*App is stopped/m, response.body)
    # The page must say how many things want a decision, and say it grammatically —
    # the header sentence and the triage count are both generated, so both can slip.
    assert_select "h1", text: /\d+ things to look at/
    assert_no_match(/\b1 things\b|things needs?\b.*needs/, response.body)
    assert_select "h2", text: "Needs attention"
    assert_match(/\d+ open/, response.body)
  end

  test "failed deployment remains separate from app runtime incident" do
    app = create_app(name: "Deploy and runtime", container_status: "dead")
    app.deployments.create!(status: "failed", started_at: 1.minute.ago, completed_at: Time.current)

    get dashboard_path

    assert_select "[data-incident-resource='Deploy and runtime']", count: 1
    assert_select "[data-incident-resource='Deploy and runtime deployment']", count: 1
  end

  test "summary counters classify every app exactly once" do
    create_app(name: "Running", container_status: "running")
    create_app(name: "Restarting", container_status: "restarting")
    create_app(name: "Stopped", status: "stopped", container_status: "paused")
    create_app(name: "Unknown", container_status: "unknown")
    create_app(name: "Stale", container_status: "running", last_status_check_at: 10.minutes.ago)
    create_app(name: "Unsupported", deploy_method: "native", container_status: "running")

    get dashboard_path

    assert_stat "running", 2
    assert_stat "stopped", 1
    assert_stat "unknown", 3
    assert_stat "total", 6
  end

  test "dashboard health remains organization scoped" do
    other = Organization.create!(name: "Other")
    other.apps.create!(name: "Secret app", slug: "secret-app", deploy_method: "docker",
                       status: "running", container_status: "dead", last_status_check_at: Time.current)

    get dashboard_path

    assert_no_match "Secret app", response.body
  end

  test "incident-first fleet rows expose truthful state and distinct actions" do
    create_app(name: "Action app", container_status: "dead", status_check_error: "docker unavailable")

    get dashboard_path

    # Triage first, then the app list. Both panels were renamed in the fleet redesign;
    # what they must still do is unchanged.
    assert_select "h2", text: "Needs attention"
    assert_select "h2", text: "Apps"
    assert_select "[data-fleet-app='Action app']" do
      assert_select "[data-health-dimension='desired']", text: /Running/
      assert_select "[data-health-dimension='observed']", text: /Dead/
      assert_select "[data-health-dimension='monitoring']", text: /Sync failed/
      # Distinct verbs on the row: read the logs, re-check state, or bounce it. Restart
      # is the destructive one and stays behind a confirm.
      assert_select "a", text: "Logs"
      assert_select "button", text: "Sync"
      assert_select "button[data-turbo-confirm]", text: "Restart"
    end
  end

  test "header and fleet publish the responsive containment contract" do
    create_app(name: "Responsive app")

    get dashboard_path

    # overflow-x-clip lives on the page shell (not the header) so it contains
    # horizontal overflow without clipping the nav/account dropdowns.
    assert_select "[data-app-shell].overflow-x-clip"
    assert_select "header [data-primary-header].min-w-0"
    assert_select "nav[data-primary-navigation].min-w-0"
    # Scrollable on mobile so no nav item is clipped/unreachable.
    assert_select "nav[data-primary-navigation].overflow-x-auto"
    assert_select "[data-account-controls].shrink-0"
    # Counts are a wrapping strip now, not a 2/4-column tile grid: it reflows instead of
    # squeezing four boxes onto a phone.
    assert_select ".flex-wrap"
    # The app list is a table, so containment moved to its own scroller — the row can be
    # wider than the phone as long as the page body still isn't.
    assert_select ".overflow-x-auto [data-fleet-app='Responsive app']"
  end

  private

  def sign_in_as(user)
    session = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{session.identifier}/#{session.token}"
  end

  def create_app(name:, **attrs)
    defaults = {
      slug: name.parameterize,
      server: @server,
      deploy_method: "docker",
      status: "running",
      container_status: "running",
      last_status_check_at: 1.minute.ago
    }
    @org.apps.create!(defaults.merge(attrs).merge(name: name))
  end

  def assert_stat(name, value)
    assert_select "[data-container-stat='#{name}']", text: value.to_s
  end
end
