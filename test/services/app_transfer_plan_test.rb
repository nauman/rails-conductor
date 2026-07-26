require "test_helper"

# App-transfer spec 26, Part 3 (Slice 5): the dry-run. Given an app and a target
# server, emit the exact change set (compute / database / edge / dns / drain)
# with ZERO mutation — the "make sense of it" artifact before any transfer runs.
class AppTransferPlanTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "xfer@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @source = @org.servers.create!(name: "box-a", status: "online", ip_address: "10.0.0.1",
                                   ssh_key: @key, ssh_user: "deploy", edge_type: "caddy")
    @target = @org.servers.create!(name: "box-b", status: "online", ip_address: "10.0.0.2",
                                   ssh_key: @key, ssh_user: "deploy", edge_type: "caddy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "app.example.com")
  end

  def plan(target: @target)
    AppTransferPlan.new(app: @app, target_server: target).call
  end

  test "emits a staged change set without mutating anything" do
    p = plan

    assert_equal @source, p.source_server
    assert_equal @target, p.target_server
    phases = p.steps.map { |s| s[:phase] }
    assert_equal %w[compute database edge cutover drain], phases
    assert_equal 0, @org.database_clusters.count, "dry-run provisions nothing"
    assert_equal 0, Database.count
  end

  test "a dedicated app plans a container provision + cold replicate" do
    detail = plan.steps.find { |s| s[:phase] == "database" }[:detail]
    assert_match(/dedicated/i, detail)
    assert_match(/appone-db/, detail)
    assert_match(/backup|restore|cold/i, detail)
  end

  test "a shared app plans a DatabasePull replication" do
    @app.update!(database_mode: "shared")
    detail = plan.steps.find { |s| s[:phase] == "database" }[:detail]
    assert_match(/DatabasePull|pg_dump/i, detail)
  end

  test "the edge step names the source→target edge translation" do
    detail = plan.steps.find { |s| s[:phase] == "edge" }[:detail]
    assert_match(/caddy/i, detail)
    assert_match(/app\.example\.com/, detail)
  end

  test "warns when the target edge is kamal-proxy (adapter pending)" do
    @target.update!(edge_type: "kamal_proxy")
    assert(plan.warnings.any? { |w| w.match?(/kamal-proxy/i) }, "expected a kamal-proxy pending warning")
  end

  test "warns when the app has no domain to repoint" do
    @app.update!(domain: nil)
    assert(plan.warnings.any? { |w| w.match?(/domain/i) })
  end

  test "refuses a transfer to the same server" do
    assert_raises(AppTransferPlan::InvalidTarget) { plan(target: @source) }
  end

  test "to_h is a serializable change set for MCP/UI" do
    h = plan.to_h
    assert_equal "box-a", h[:source][:server]
    assert_equal "box-b", h[:target][:server]
    assert h[:steps].is_a?(Array)
    assert h.key?(:warnings)
  end
end
