require "test_helper"

class FleetSituationFlappingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "flap@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Flap Co")
    @server = Server.create!(name: "flap-box", status: "online", organization: @org)
    @app = @org.apps.create!(name: "Flapper", slug: "flapper", server: @server,
                             deploy_method: "kamal", domain: "flapper.test")
  end

  def check!(up:, error: nil, at: Time.current)
    @app.site_checks.create!(up: up, status_code: up ? 200 : nil, error: error, checked_at: at)
  end

  def situation = FleetSituation.new(server_scope: Server.where(id: @server.id)).snapshot[:needs_attention]

  test "a site that keeps recovering on retry is surfaced as flapping, not silently healthy" do
    3.times { |i| check!(up: true, error: "#{SiteMonitor::RECOVERED} — first probe: timeout", at: i.minutes.ago) }

    row = situation.find { |r| r[:kind] == "site_flapping" }
    assert row, "expected a site_flapping row: #{situation.inspect}"
    assert_equal "Flapper", row[:app]
    assert_match(/unstable/, row[:detail])
  end

  test "a single recovery is not yet a pattern" do
    check!(up: true, error: "#{SiteMonitor::RECOVERED} — first probe: timeout")
    check!(up: true, at: 1.minute.ago)

    assert_nil situation.find { |r| r[:kind] == "site_flapping" }
  end

  test "a genuinely down site still reports site_down and not flapping" do
    check!(up: false, error: "no response (confirmed by a second probe)")

    kinds = situation.map { |r| r[:kind] }
    assert_includes kinds, "site_down"
    refute_includes kinds, "site_flapping"
  end
end
