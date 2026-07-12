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
    assert_select "section h1", text: "Background Jobs"
  end

  test "unexpected Turbo Frame ID falls back to the full jobs page" do
    with_stats(available_stats) do
      get jobs_app_path(@managed_app), headers: { "Turbo-Frame" => "unexpected_frame" }
    end

    assert_response :success
    assert_select "section h1", text: "Background Jobs"
    assert_select "turbo-frame#app_jobs_#{@managed_app.id}", count: 0
  end

  private

  def with_stats(stats, &block)
    SolidQueueStats.stub(:for, stats, &block)
  end

  def available_stats
    SolidQueueStats::Result.new(available: true, error: nil, workers: [], pending: 2, running: 1, scheduled: 3, failed: 0)
  end

  def unavailable_stats
    SolidQueueStats::Result.new(available: false, error: "not configured", workers: [], pending: 0, running: 0, scheduled: 0, failed: 0)
  end
end
