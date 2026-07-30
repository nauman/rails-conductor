require "test_helper"

class AppJobsTest < ActionDispatch::IntegrationTest
  setup do
    user = User.create!(email: "jobs@example.com")
    @org = Organization.create_for(user, name: "Jobs")
    @org.update!(onboarded_at: Time.current)
    @managed_app = @org.apps.create!(name: "Jobs app", slug: "jobs-app", deploy_method: "docker")
    session = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{session.identifier}/#{session.token}"
  end

  test "canonical Turbo Frame request returns exactly its requested frame" do
    with_stats(available_stats) do
      get jobs_app_path(@managed_app), headers: { "Turbo-Frame" => "app_jobs_#{@managed_app.id}" }
    end

    assert_response :success
    assert_select "turbo-frame#app_jobs_#{@managed_app.id}", count: 1
    assert_select "section", count: 0
  end

  test "unavailable frame renders operator copy instead of missing content" do
    with_stats(unavailable_stats) do
      get jobs_app_path(@managed_app), headers: { "Turbo-Frame" => "app_jobs_#{@managed_app.id}" }
    end

    assert_select "turbo-frame#app_jobs_#{@managed_app.id}", text: /No job data/
  end

  test "normal HTML request renders the full jobs page" do
    with_stats(available_stats) { get jobs_app_path(@managed_app) }

    assert_response :success
    # The headline states the queue's condition rather than naming the page.
    assert_select "h1", text: "Queue is keeping up."
  end

  # A count with nothing to click is not actionable: the page must name what broke and
  # group repeats, because the same job failing 14 times is one problem.
  test "failed jobs are named and grouped by cause" do
    failures = [
      { job_class: "SendDigestJob", queue: "default", error: "PG::ConnectionBad: could not connect", failed_at: 5.minutes.ago },
      { job_class: "SendDigestJob", queue: "default", error: "PG::ConnectionBad: could not connect", failed_at: 1.hour.ago },
      { job_class: "ThumbnailJob", queue: "media", error: "Vips::Error: unsupported format", failed_at: 2.hours.ago }
    ]
    with_stats(stats(failed: 3, failures: failures)) { get jobs_app_path(@managed_app) }

    assert_select "h1", text: "3 jobs failed."
    assert_select "[data-job-failure='SendDigestJob']", count: 1
    assert_select "[data-job-failure='SendDigestJob']", text: /2 times/
    assert_select "[data-job-failure='SendDigestJob']", text: /PG::ConnectionBad/
    assert_select "[data-job-failure='ThumbnailJob']", count: 1
  end

  # Queued work with no live worker never runs, yet a counter-only page reads as calm.
  test "queued work with no live worker is stated as the headline" do
    with_stats(stats(workers: [], pending: 5, oldest_pending_at: 20.minutes.ago)) { get jobs_app_path(@managed_app) }

    assert_select "h1", text: "5 jobs queued, nothing running them."
    assert_match(/will simply never run/, response.body)
  end

  test "unexpected Turbo Frame ID falls back to the full jobs page" do
    with_stats(available_stats) do
      get jobs_app_path(@managed_app), headers: { "Turbo-Frame" => "unexpected_frame" }
    end

    assert_response :success
    assert_select "h1", text: "Queue is keeping up."
    assert_select "turbo-frame#app_jobs_#{@managed_app.id}", count: 0
  end

  private

  def with_stats(stats, &block)
    SolidQueueStats.stub(:for, stats, &block)
  end

  def available_stats = stats

  def stats(**overrides)
    SolidQueueStats::Result.new(**{
      available: true, error: nil,
      workers: [ { name: "worker-1", kind: "Worker", last_heartbeat_at: Time.current, alive: true } ],
      pending: 2, running: 1, scheduled: 3, failed: 0, failures: [], oldest_pending_at: nil
    }.merge(overrides))
  end

  def unavailable_stats
    SolidQueueStats::Result.new(available: false, error: "not configured", workers: [], pending: 0,
                                running: 0, scheduled: 0, failed: 0, failures: [], oldest_pending_at: nil)
  end
end
