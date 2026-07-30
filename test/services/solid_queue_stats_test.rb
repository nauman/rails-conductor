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

  test "unavailable result carries no failure detail" do
    result = SolidQueueStats.for(@app)

    assert_empty result.failures
    assert_nil result.oldest_pending_at
  end

  # A count of 14 failures with nothing to click is not actionable, so the Result must be
  # able to name what broke. These exercise the shape the view depends on.
  test "failure detail summarises the job and its error" do
    failure = { job_class: "SendDigestJob", queue: "default", error: "PG::ConnectionBad: could not connect",
                failed_at: 2.hours.ago }
    result = SolidQueueStats::Result.new(available: true, error: nil, workers: [], pending: 3, running: 0,
                                        scheduled: 0, failed: 1, failures: [ failure ], oldest_pending_at: 1.hour.ago)

    assert_equal "SendDigestJob", result.failures.first[:job_class]
    assert result.degraded?
    assert_not result.healthy?
  end

  test "pending work with no live worker is called out separately from failures" do
    stalled = SolidQueueStats::Result.new(available: true, error: nil, workers: [], pending: 5, running: 0,
                                         scheduled: 0, failed: 0, failures: [], oldest_pending_at: 30.minutes.ago)

    assert stalled.stalled?
    assert stalled.degraded?

    working = SolidQueueStats::Result.new(available: true, error: nil,
                                         workers: [ { name: "w1", kind: "Worker", last_heartbeat_at: Time.current, alive: true } ],
                                         pending: 5, running: 1, scheduled: 0, failed: 0, failures: [], oldest_pending_at: 1.minute.ago)

    assert_not working.stalled?
  end

  test "unavailable result is neither healthy nor degraded" do
    result = SolidQueueStats.for(@app)

    assert_not result.healthy?
    assert_not result.degraded?
    assert_equal 0, result.workers_alive
    assert_equal 0, result.workers_total
  end
end
