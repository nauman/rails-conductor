require "test_helper"

class DeployPreflightTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "pf@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy",
                                   last_audit_status: "secure", last_audit_at: Time.current)
    @app = @org.apps.create!(name: "App", server: @server, status: "stopped",
                             deploy_method: "kamal", repository_url: "https://github.com/x/y")
  end

  def check(app = @app) = DeployPreflight.new(app).check
  def row(res, key) = res.checks.find { |c| c.key == key }

  test "a fresh secure kamal app with seeds and no hold is clear" do
    @app.seed_applications.create!(status: "succeeded", applied_at: Time.current)
    r = check
    assert_equal :clear, r.status
    refute r.blocked?
    assert r.checks.all? { |c| %i[ok skip].include?(c.status) },
      "all rows should be ok or not applicable: #{r.checks.map { |c| [ c.key, c.status ] }.inspect}"
  end

  test "an at_risk server audit is a fail and blocks the deploy" do
    @server.update!(last_audit_status: "at_risk")
    r = check
    assert_equal :fail, row(r, :audit).status
    assert r.blocked?
    assert_equal :blocked, r.status
  end

  test "a never-audited server warns but does not block" do
    @server.update!(last_audit_status: nil, last_audit_at: nil)
    r = check
    assert_equal :warn, row(r, :audit).status
    refute r.blocked?
  end

  test "a stale audit (older than 7 days) warns" do
    @server.update!(last_audit_at: 10.days.ago)
    assert_equal :warn, row(check, :audit).status
  end

  test "a deploy hold (owed thread) is a fail and blocks, surfacing the reason" do
    @app.update!(deploy_hold: true, deploy_hold_reason: "thread subdomains-edge owed")
    r = check
    assert_equal :fail, row(r, :threads).status
    assert_match(/subdomains-edge/, row(r, :threads).detail)
    assert r.blocked?
  end

  test "a Caddy container app without a recorded host port is blocked" do
    @server.update!(edge_type: "caddy")

    result = check
    port_row = row(result, :published_port)

    assert port_row, "preflight must surface the missing infrastructure coordinate"
    assert_equal :fail, port_row.status
    assert_match(/host-published port/, port_row.detail)
    assert result.blocked?
  end

  test "a Kamal-proxy app does not need a host-published port" do
    @server.update!(edge_type: "kamal_proxy")

    port_row = row(check, :published_port)
    assert port_row, "preflight must explain why no host port is required"
    assert_equal :skip, port_row.status
  end

  test "kamal migrations are gated (ok); docker/native are not (warn)" do
    assert_equal :ok, row(check, :migrations).status
    @app.update!(deploy_method: "docker")
    assert_equal :warn, row(check, :migrations).status
    @app.update!(deploy_method: "native")
    assert_equal :warn, row(check, :migrations).status
  end

  test "an app that has never recorded a seed run warns" do
    assert_equal :warn, row(check, :seeds).status
  end

  test "the most recent seed run failing is a fail and blocks (not hidden by an older success)" do
    @app.seed_applications.create!(status: "succeeded", applied_at: 2.days.ago)
    @app.seed_applications.create!(status: "failed", applied_at: 1.hour.ago)
    r = check
    assert_equal :fail, row(r, :seeds).status
    assert r.blocked?
  end

  test "a queued seed retry (seed_on_next_deploy) does not block the deploy that repairs it" do
    @app.update!(seed_on_next_deploy: true)
    @app.seed_applications.create!(status: "failed", applied_at: 1.hour.ago)
    r = check
    assert_equal :warn, row(r, :seeds).status, "the queued retry downgrades the fail to a warning"
    refute r.blocked?, "the very deploy that would re-run the failed seeds must not be blocked by them"
  end

  test "a succeeded latest seed run is ok" do
    @app.seed_applications.create!(status: "failed", applied_at: 2.days.ago)
    @app.seed_applications.create!(status: "succeeded", applied_at: 1.hour.ago)
    assert_equal :ok, row(check, :seeds).status
  end

  test "a succeeded seed row WITHOUT evidence (no applied_at) is unproven — warns, not green" do
    @app.seed_applications.create!(status: "succeeded", applied_at: nil)
    assert_equal :warn, row(check, :seeds).status
    refute check.blocked?
  end

  test "a pending seed row does not make the gate green" do
    @app.seed_applications.create!(status: "pending")
    assert_equal :warn, row(check, :seeds).status
  end

  test "an unrecognized audit status does NOT fail open to secure — it warns" do
    @server.update!(last_audit_status: "definitely-not-a-real-status", last_audit_at: Time.current)
    assert_equal :warn, row(check, :audit).status
    refute check.blocked?
  end

  test "a server-less app skips the audit check without erroring" do
    @app.update_columns(server_id: nil)
    r = check(@app.reload)
    assert_equal :skip, row(r, :audit).status
    refute r.blocked?
  end
end
