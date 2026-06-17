require "test_helper"

# FleetStatusTool gains an OPTIONAL organization_id filter. When supplied it
# scopes Server.all to that org; when omitted it stays admin-global (all servers).
class FleetStatusOrgScopeTest < ActiveSupport::TestCase
  setup do
    @org_a = Organization.create!(name: "Org A")
    @org_b = Organization.create!(name: "Org B")
    @server_a = Server.create!(name: "fleet-a", status: "online", organization: @org_a)
    @server_b = Server.create!(name: "fleet-b", status: "online", organization: @org_b)
    @server_global = Server.create!(name: "fleet-none", status: "online")
  end

  test "without organization_id returns all servers (admin-global)" do
    result = FleetStatusTool.new(user: nil).call({})

    assert result.success?
    names = result.value.map { |s| s[:name] }
    assert_includes names, "fleet-a"
    assert_includes names, "fleet-b"
    assert_includes names, "fleet-none"
  end

  test "with organization_id returns only that org's servers" do
    result = FleetStatusTool.new(user: nil).call("organization_id" => @org_a.id)

    assert result.success?
    names = result.value.map { |s| s[:name] }
    assert_equal [ "fleet-a" ], names
  end
end
