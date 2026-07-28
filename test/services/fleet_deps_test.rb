require "test_helper"

# FleetDeps is the real infra binding; these cover the two audit-fixed paths that
# are pure enough to assert without a live server: the drain targets the REAL
# container (audit #7), not the bare slug.
class FleetDepsTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "fleetdeps@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @source = @org.servers.create!(name: "a", status: "online", ip_address: "10.0.0.1", ssh_key: key, ssh_user: "deploy")
    @target = @org.servers.create!(name: "b", status: "online", ip_address: "10.0.0.2", ssh_key: key, ssh_user: "deploy")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare", api_key: "k", account_id: "a1")
  end

  def deps_for(app)
    t = AppTransfer.create!(app: app, organization: @org, source_server: @source, target_server: @target)
    AppTransferRunner::FleetDeps.new(t, credential: @cred, bucket: "b")
  end

  test "drain targets the Kamal service container by label, not the slug" do
    app = @org.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                            repository_url: "https://github.com/x/y.git")
    cmd = deps_for(app).send(:drain_command)
    assert_includes cmd, "label=service="
    assert_includes cmd, "docker stop"
    refute_equal %(docker stop appone 2>/dev/null || true), cmd, "must not stop the bare slug"
  end

  test "drain targets conductor-<slug> for a docker app" do
    app = @org.apps.create!(name: "Dock", slug: "dock", server: @source, deploy_method: "docker",
                            repository_url: "https://github.com/x/y.git")
    cmd = deps_for(app).send(:drain_command)
    assert_includes cmd, "docker stop #{app.container_name}"
    assert_includes cmd, "conductor-dock"
  end
end
