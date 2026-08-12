require "test_helper"

class EdgeAppToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "edge-tool@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Edge Tools")
    @server = @org.servers.create!(name: "caddy", status: "online", edge_type: "caddy")
    @app = @org.apps.create!(name: "Edge App", slug: "edge-app", server: @server,
                             deploy_method: "kamal", domain: "edge.example.com",
                             status: "running", container_status: "running",
                             last_status_check_at: Time.current)
  end

  test "edge action dispatches through the stable operation vocabulary" do
    fake = Object.new
    fake.define_singleton_method(:call) { |operation, message:| [ operation, message ] }

    result = EdgeAppTool.new(user: @user, operations_factory: ->(_app, _user) { fake }).call(
      "app_id" => @app.id, "operation" => "maintenance", "confirm" => true, "message" => "planned"
    )

    assert result.success?, result.error
    assert_equal "Edge App", result.value[:app]
    assert_equal "maintenance", result.value[:operation]
    assert_equal [ "maintenance", "planned" ], result.value[:result]
  end

  test "mutating edge operations require explicit confirmation" do
    result = EdgeAppTool.new(user: @user).call("app_id" => @app.id, "operation" => "live")

    refute result.success?
    assert_match(/confirm/i, result.error)
  end

  test "edge operation rejects unknown operations" do
    result = EdgeAppTool.new(user: @user).call("app_id" => @app.id, "operation" => "deploy")

    refute result.success?
    assert_match(/operation/i, result.error)
  end
end
