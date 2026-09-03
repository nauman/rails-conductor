require "test_helper"

# DeployPreflight weighed freshness ONLY inside the `secure` branch. So a stale
# `secure` correctly degraded to a warning — but a stale `at_risk` blocked deploys
# forever, and a stale `attention` was reported as current.
#
# Both directions are wrong for the same reason: an old grade is evidence about the
# past. A ten-month-old at_risk blocks a box that may since have been fixed, with no
# way to clear it except an audit nobody is scheduled to run.
class DeployPreflightAuditFreshnessTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "pfa@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.31")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
  end

  def audit_row(status, at)
    @server.update_columns(last_audit_status: status, last_audit_at: at)
    DeployPreflight.new(@app).check.checks.find { |c| c.key == :audit }
  end

  test "a FRESH at_risk still blocks — real exposure must stop a deploy" do
    assert_equal :fail, audit_row("at_risk", 1.day.ago).status
  end

  test "a stale at_risk warns instead of blocking forever" do
    row = audit_row("at_risk", 90.days.ago)

    assert_equal :warn, row.status, "a 90-day-old finding is not evidence about today"
    assert_match(/stale|re-?run|old/i, row.detail)
  end

  test "a fresh secure clears" do
    assert_equal :ok, audit_row("secure", 1.day.ago).status
  end

  test "a stale secure warns — unchanged, it was already right" do
    assert_equal :warn, audit_row("secure", 90.days.ago).status
  end

  test "a stale attention is not reported as current" do
    row = audit_row("attention", 90.days.ago)

    assert_equal :warn, row.status
    assert_match(/stale|re-?run|old/i, row.detail)
  end

  test "never audited still warns" do
    assert_equal :warn, audit_row(nil, nil).status
  end
end
