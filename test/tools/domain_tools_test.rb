require "test_helper"

class DomainToolsTest < ActiveSupport::TestCase
  def test_add_domain_tool_uses_caddy_client
    server = Server.create!(name: "edge-tool-1", status: "online")
    fake_client = Struct.new(:route) do
      def upsert_route(**)
        route
      end
    end.new({ "route_id" => "conductor-route-example-com", "action" => "created" })

    CaddyClient.stub(:new, fake_client) do
      result = AddDomainTool.new(user: nil).call(
        "server_id" => server.id,
        "domain" => "example.com",
        "upstream" => "127.0.0.1:3000"
      )

      assert result.success?
      assert_equal "created", result.value[:action]
      assert_equal "conductor-route-example-com", result.value[:route_id]
    end
  end

  def test_remove_domain_tool_uses_caddy_client
    server = Server.create!(name: "edge-tool-2", status: "online")
    fake_client = Struct.new(:route) do
      def remove_route(_domain)
        route
      end
    end.new({ "route_id" => "conductor-route-example-com", "action" => "removed" })

    CaddyClient.stub(:new, fake_client) do
      result = RemoveDomainTool.new(user: nil).call(
        "server_id" => server.id,
        "domain" => "example.com"
      )

      assert result.success?
      assert_equal "removed", result.value[:action]
      assert_equal "conductor-route-example-com", result.value[:route_id]
    end
  end
end
