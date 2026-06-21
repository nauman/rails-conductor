require "test_helper"

# ConductorReadTool is the consolidated, flat `action`-enum read tool — the
# pattern-setter for the 18→7 MCP consolidation. It delegates to the existing
# single-purpose implementation classes (FleetStatusTool, RecentLogsTool,
# DeploymentLogTool) so behaviour is reused, not duplicated.
class ConductorReadToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "cr@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    @server = Server.create!(name: "fleet-a", status: "online", organization: @org)
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal")
    @deployment = @app.deployments.create!(status: "deploying", log: "l1\nl2\nl3\n")
  end

  test "action=fleet_status delegates to FleetStatusTool" do
    res = ConductorReadTool.new(user: @user).call("action" => "fleet_status")
    assert res.success?
    assert_includes res.value.map { |s| s[:name] }, "fleet-a"
  end

  test "action=logs delegates to RecentLogsTool" do
    res = ConductorReadTool.new(user: @user).call("action" => "logs")
    assert res.success?
    assert_kind_of Array, res.value
  end

  test "action=deployment delegates to DeploymentLogTool and passes params through" do
    res = ConductorReadTool.new(user: @user).call("action" => "deployment", "app_name" => "Kuickr", "tail" => 1)
    assert res.success?
    assert_equal @deployment.id, res.value[:deployment_id]
    assert_equal "l3\n", res.value[:log]
  end

  test "missing action fails with a legible, steering error listing valid actions" do
    res = ConductorReadTool.new(user: @user).call({})
    refute res.success?
    assert_match(/action/, res.error)
    assert_match(/fleet_status/, res.error)
  end

  test "unknown action fails cleanly" do
    res = ConductorReadTool.new(user: @user).call("action" => "bogus")
    refute res.success?
    assert_match(/bogus/, res.error)
  end

  test "is registered and allowed for read-only tokens" do
    assert_equal ConductorReadTool, ToolRegistry.find("conductor_read")
    assert_includes ToolRegistry::READ_ONLY_TOOLS, "conductor_read"
  end
end
