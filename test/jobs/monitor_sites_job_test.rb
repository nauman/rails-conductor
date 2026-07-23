require "test_helper"

class MonitorSitesJobTest < ActiveJob::TestCase
  setup do
    user = User.create!(email: "msj@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @app = @org.apps.create!(name: "Site", slug: "site", deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "example.com")
  end

  test "prunes samples older than the retention window and keeps recent ones" do
    old = @app.site_checks.create!(checked_at: 8.days.ago, up: true, ttfb_ms: 100)
    recent = @app.site_checks.create!(checked_at: 1.hour.ago, up: true, ttfb_ms: 100)

    noop = Object.new
    def noop.check! = nil
    SiteMonitor.stub(:new, noop) { MonitorSitesJob.perform_now }

    refute SiteCheck.exists?(old.id), "old samples should be pruned"
    assert SiteCheck.exists?(recent.id), "recent samples should be kept"
  end

  test "checks apps that have a domain, skips those without" do
    @org.apps.create!(name: "NoDomain", slug: "nd", deploy_method: "kamal",
                      repository_url: "https://github.com/x/z.git") # no domain

    checked = []
    monitor = Object.new
    monitor.define_singleton_method(:check!) { nil }
    SiteMonitor.stub(:new, ->(app) { checked << app.name; monitor }) { MonitorSitesJob.perform_now }

    assert_includes checked, "Site"
    refute_includes checked, "NoDomain"
  end
end
