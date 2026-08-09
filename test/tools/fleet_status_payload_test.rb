require "test_helper"

# The per-app half of fleet_status. The box's edge is already reported per
# server; an app's own *form* — how it is deployed and on which port it is
# published — decides whether that box edge actually serves it. Leaving those
# out of the payload forces an agent to read free-text notes (or SSH) to learn
# facts Conductor already stores.
class FleetStatusPayloadTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "fsp@example.com", admin: true)
    @org  = Organization.create_for(@user, name: "Payload Co")
    @server = Server.create!(
      name: "edge-box", status: "online", organization: @org,
      edge_type: "caddy", edge_detail: "Host Caddy (Admin API)", edge_checked_at: Time.current
    )
  end

  def app_payload(name)
    res = FleetStatusTool.new(user: @user).call({})
    assert res.success?
    res.value.flat_map { |s| s[:apps] }.find { |a| a[:name] == name }
  end

  test "an app reports the deploy method and published port Conductor already stores" do
    @org.apps.create!(name: "Ported", slug: "ported", server: @server, deploy_method: "kamal", port: 9060)

    payload = app_payload("Ported")
    assert_equal "kamal", payload[:deploy_method], "deploy_method is stored on apps but withheld from the read"
    assert_equal 9060, payload[:port], "port is stored on apps but withheld from the read"
  end

  test "the box edge is still reported per server so app form can be compared against it" do
    @org.apps.create!(name: "Plain", slug: "plain", server: @server, deploy_method: "docker")

    server = FleetStatusTool.new(user: @user).call({}).value.find { |s| s[:name] == "edge-box" }
    assert_equal "caddy", server[:edge][:type]
    assert_equal "docker", app_payload("Plain")[:deploy_method]
  end
end
