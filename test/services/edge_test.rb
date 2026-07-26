require "test_helper"

# App-transfer spec 26, Part 2: uniform edge publishing. Edge.for(server)
# dispatches by Server#edge_type so "publish this domain on box B" is the same
# call regardless of B's edge.
class EdgeTest < ActiveSupport::TestCase
  class FakeCaddy
    attr_reader :upserted, :removed
    def upsert_route(domain:, upstream:)
      @upserted = { domain: domain, upstream: upstream }
      { "route_id" => "route-1", "action" => "created" }
    end

    def remove_route(domain)
      @removed = domain
      { "action" => "removed" }
    end
  end

  setup do
    user = User.create!(email: "edge@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
  end

  def server(edge_type)
    @org.servers.create!(name: "s-#{edge_type}", status: "online", ip_address: "10.0.0.9",
                         ssh_key: @key, ssh_user: "deploy", edge_type: edge_type)
  end

  test "Edge.for dispatches to the adapter for the server's edge_type" do
    assert_instance_of Edge::CaddyAdapter, Edge.for(server("caddy"))
    assert_instance_of Edge::KamalProxyAdapter, Edge.for(server("kamal_proxy"))
  end

  test "Edge.for raises for an unsupported edge" do
    assert_raises(Edge::UnsupportedEdge) { Edge.for(server("none")) }
  end

  test "CaddyAdapter#publish delegates to CaddyClient#upsert_route" do
    fake = FakeCaddy.new
    result = Edge.for(server("caddy"), client: fake).publish(domain: "app.example.com", upstream: "localhost:3000")

    assert_equal({ domain: "app.example.com", upstream: "localhost:3000" }, fake.upserted)
    assert_equal "caddy", result[:edge]
    assert_equal "route-1", result[:route_id]
    assert_equal "created", result[:action]
  end

  test "CaddyAdapter#unpublish delegates to CaddyClient#remove_route" do
    fake = FakeCaddy.new
    result = Edge.for(server("caddy"), client: fake).unpublish(domain: "app.example.com")

    assert_equal "app.example.com", fake.removed
    assert_equal "caddy", result[:edge]
  end

  test "KamalProxyAdapter is a defined seam pending the deployer's kamal-proxy work" do
    adapter = Edge.for(server("kamal_proxy"))
    assert_raises(Edge::KamalProxyAdapter::Pending) { adapter.publish(domain: "a.com", upstream: "localhost:3000") }
    assert_raises(Edge::KamalProxyAdapter::Pending) { adapter.unpublish(domain: "a.com") }
  end
end
