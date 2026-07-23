require "test_helper"

class FleetSituationTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "fs@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git")
  end

  def snap = FleetSituation.new(server_scope: @org.servers).snapshot

  test "an in-flight deployment shows under in_flight" do
    d = @app.deployments.create!(status: "deploying")
    s = snap
    assert s[:in_flight].any? { |o| o[:type] == "deployment" && o[:id] == d.id }
  end

  test "a blocked deploy becomes a needs_attention item with the app + blockers + runbook state" do
    @app.update!(deploy_hold: true, deploy_hold_reason: "thread owed")
    @app.start_deployment!  # persists a blocked deployment
    item = snap[:needs_attention].find { |i| i[:kind] == "blocked_deploy" }
    assert item, "expected a blocked_deploy attention item"
    assert_equal "Appone", item[:app]
    assert item.key?(:runbook)
    assert item.key?(:checklist)
  end

  test "an at-risk server surfaces in needs_attention" do
    @server.update!(last_audit_status: "at_risk")
    assert snap[:needs_attention].any? { |i| i[:kind] == "at_risk_server" }
  end

  test "a failed latest seed run surfaces in needs_attention" do
    @app.seed_applications.create!(status: "failed", applied_at: Time.current)
    assert snap[:needs_attention].any? { |i| i[:kind] == "failed_seed" && i[:app] == "Appone" }
  end

  test "a failed deploy carries the actionable reason inline" do
    d = @app.deployments.create!(status: "building")
    d.fail!("Missing required env var(s): SES_SMTP_USERNAME, SES_SMTP_PASSWORD.")
    item = snap[:needs_attention].find { |i| i[:kind] == "failed_deploy" && i[:app] == "Appone" }
    assert item, "expected a failed_deploy attention item"
    assert_equal d.id, item[:deployment_id]
    assert_includes item[:reason], "SES_SMTP_USERNAME"
  end

  test "a down public URL surfaces in needs_attention with the status/error detail" do
    @app.site_checks.create!(checked_at: Time.current, up: false, status_code: 502, error: "Bad Gateway")
    item = snap[:needs_attention].find { |i| i[:kind] == "site_down" && i[:app] == "Appone" }
    assert item, "expected a site_down attention item"
    assert_includes item[:detail], "502"
    assert_includes item[:detail], "Bad Gateway"
  end

  test "recent lists terminal deployments newest-first, excluding in-flight" do
    @app.deployments.create!(status: "succeeded", commit_sha: "aaaaaaa1")
    @app.deployments.create!(status: "deploying") # in-flight, excluded from recent
    recent = snap[:recent]
    assert recent.any? { |d| d[:status] == "succeeded" }
    refute recent.any? { |d| d[:status] == "deploying" }
  end

  test "the snapshot is tenant-scoped — another org's fleet is invisible" do
    other_user = User.create!(email: "other@example.com")
    other = Organization.create_for(other_user, name: "Other")
    okey = SshKey.create!(name: "k2", private_key: valid_private_key, organization: other)
    osrv = other.servers.create!(name: "theirs", status: "online", ip_address: "192.0.2.99", ssh_key: okey)
    oapp = other.apps.create!(name: "Theirs", slug: "theirs", server: osrv, deploy_method: "kamal",
                              repository_url: "https://github.com/x/z.git")
    oapp.deployments.create!(status: "deploying")

    assert snap[:in_flight].none? { |o| o[:app] == "Theirs" }, "must not leak another org's ops"
  end
end
