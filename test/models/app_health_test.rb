require "test_helper"

class AppHealthTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "health@example.com")
    @org = Organization.create_for(user, name: "Health")
    key = SshKey.create!(name: "health-key", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "health-host", status: "online", ip_address: "10.0.0.10",
                                   ssh_key: key, ssh_user: "deploy")
  end

  test "stopped is desired stopped while lifecycle states remain desired running" do
    assert_equal "stopped", health(status: "stopped").desired_state

    %w[running deploying failed].each do |status|
      assert_equal "running", health(status: status).desired_state
    end
  end

  test "monitoring precedence is unsupported unavailable failed never stale fresh" do
    assert_equal "unsupported", health(deploy_method: "native").monitoring_state
    assert_equal "unavailable", health(server: nil).monitoring_state
    assert_equal "failed", health(status_check_error: "ssh failed", last_status_check_at: Time.current).monitoring_state
    assert_equal "never_checked", health(last_status_check_at: nil).monitoring_state
    assert_equal "stale", health(last_status_check_at: 6.minutes.ago).monitoring_state
    assert_equal "fresh", health(last_status_check_at: 1.minute.ago).monitoring_state
  end

  test "desired running incident matrix is actionable and truthful" do
    assert_nil health(container_status: "running").incident
    assert_nil health(container_status: "restarting").incident

    %w[exited dead paused].each do |observed|
      incident = health(container_status: observed).incident
      assert_equal "critical", incident[:severity]
      assert_equal "Expected running, observed #{observed}", incident[:message]
      assert_equal "logs", incident[:action]
    end

    unknown = health(container_status: "unknown").incident
    assert_equal "warning", unknown[:severity]
    assert_equal "Runtime not observed", unknown[:message]
    assert_equal "sync", unknown[:action]
  end

  test "monitoring uncertainty overrides cached observations for desired running" do
    failed = health(container_status: "running", status_check_error: "permission denied").incident
    assert_equal "Status check failed", failed[:message]
    assert_equal "sync", failed[:action]

    stale = health(container_status: "running", last_status_check_at: 6.minutes.ago).incident
    assert_equal "Container status is stale", stale[:message]

    never = health(container_status: "running", last_status_check_at: nil).incident
    assert_equal "Container has never been checked", never[:message]

    unavailable = health(container_status: "running", server: nil).incident
    assert_equal "Monitoring unavailable: no server", unavailable[:message]

    assert_nil health(container_status: "running", deploy_method: "native").incident
  end

  test "desired stopped only alerts on trustworthy evidence that it is running" do
    %w[exited dead paused unknown].each do |observed|
      assert_nil health(status: "stopped", container_status: observed).incident
    end

    %w[running restarting].each do |observed|
      incident = health(status: "stopped", container_status: observed).incident
      assert_equal "warning", incident[:severity]
      assert_equal "Running unexpectedly", incident[:message]
      assert_equal "app", incident[:action]
    end

    assert_nil health(status: "stopped", container_status: "running", last_status_check_at: 6.minutes.ago).incident
    assert_nil health(status: "stopped", container_status: "running", status_check_error: "timeout").incident
  end

  test "monitoring context labels every row" do
    assert_equal "Unsupported · not checked", health(deploy_method: "native").monitoring_label
    assert_equal "Unavailable · no server", health(server: nil).monitoring_label
    assert_equal "Sync failed · permission denied", health(status_check_error: "permission denied").monitoring_label
    assert_equal "Never checked", health(last_status_check_at: nil).monitoring_label
    assert_match(/Checked 6 minutes ago · stale/, health(last_status_check_at: 6.minutes.ago).monitoring_label)
    assert_match(/Checked 1 minute ago/, health(last_status_check_at: 1.minute.ago).monitoring_label)
  end

  private

  def health(**attrs)
    defaults = {
      name: "App #{SecureRandom.hex(3)}",
      slug: "app-#{SecureRandom.hex(4)}",
      server: @server,
      deploy_method: "docker",
      status: "running",
      container_status: "running",
      last_status_check_at: 1.minute.ago,
      status_check_error: nil
    }
    AppHealth.new(@org.apps.create!(defaults.merge(attrs)))
  end
end
