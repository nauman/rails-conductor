require "test_helper"

class SolidQueueStatsTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "solid-queue@example.com")
    org = Organization.create_for(user, name: "Solid Queue")
    @app = org.apps.create!(name: "Queue app", slug: "queue-app", deploy_method: "docker")
  end

  test "missing database URL is unavailable without raising" do
    result = SolidQueueStats.for(@app)

    assert_not result.available
    assert_equal "no database URL configured", result.error
    assert_equal 0, result.pending
    assert_equal 0, result.failed
  end

  test "unavailable result is neither healthy nor degraded" do
    result = SolidQueueStats.for(@app)

    assert_not result.healthy?
    assert_not result.degraded?
    assert_equal 0, result.workers_alive
    assert_equal 0, result.workers_total
  end
end
