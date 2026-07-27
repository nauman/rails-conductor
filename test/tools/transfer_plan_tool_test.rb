require "test_helper"

# App-transfer spec 26: the read-only transfer_plan MCP action returns the staged
# change set for moving an app to another server, mutating nothing.
class TransferPlanToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "xfer-tool@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @source = @org.servers.create!(name: "box-a", status: "online", ip_address: "10.0.0.1", ssh_key: key, edge_type: "caddy")
    @target = @org.servers.create!(name: "box-b", status: "online", ip_address: "10.0.0.2", ssh_key: key, edge_type: "caddy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "app.example.com")
  end

  test "transfer_plan emits the change set without mutating" do
    res = ConductorAppTool.new(user: @user).call(
      "action" => "transfer_plan", "app_name" => "Appone", "target_server_name" => "box-b"
    )
    assert res.success?, res.error

    v = res.value
    assert_equal "box-a", v[:source][:server]
    assert_equal "box-b", v[:target][:server]
    assert_equal %w[database compute edge cutover drain], v[:steps].map { |s| s[:phase] }
    assert_equal 0, AppTransfer.count, "dry-run creates no transfer record"
    assert_equal 0, @org.database_clusters.count
  end

  test "transfer_plan rejects the same server" do
    res = ConductorAppTool.new(user: @user).call(
      "action" => "transfer_plan", "app_name" => "Appone", "target_server_name" => "box-a"
    )
    refute res.success?
    assert_match(/differ/, res.error)
  end

  test "transfer_plan reports a missing target server" do
    res = ConductorAppTool.new(user: @user).call(
      "action" => "transfer_plan", "app_name" => "Appone", "target_server_name" => "nope"
    )
    refute res.success?
    assert_match(/Target server not found/, res.error)
  end
end
