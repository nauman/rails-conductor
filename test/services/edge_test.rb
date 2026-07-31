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

  # Instant cut-over via the kamal-proxy CLI over SSH.
  class FakeSsh
    attr_reader :commands
    def initialize(success: true) = (@commands = []; @success = success)
    def execute_with_status(cmd)
      @commands << cmd
      { success: @success, output: @success ? "" : "boom", stdout: "", stderr: @success ? "" : "boom", exit_code: @success ? 0 : 1 }
    end
  end

  test "KamalProxyAdapter#publish registers the host on kamal-proxy via its CLI" do
    ssh = FakeSsh.new
    result = Edge.for(server("kamal_proxy"), ssh: ssh).publish(domain: "a.com", upstream: "app-web:3000")

    assert_equal "kamal_proxy", result[:edge]
    assert_equal "a.com", result[:domain]
    assert_equal "kamal-proxy", result[:applied_by]
    cmd = ssh.commands.find { |c| c.include?("kamal-proxy deploy") }
    assert cmd, "expected a publish command; got #{ssh.commands.inspect}"
    assert_includes cmd, "docker exec kamal-proxy kamal-proxy deploy"
    assert_includes cmd, "--host a.com"
    assert_includes cmd, "--target app-web:3000"
    assert_includes cmd, "--tls"
  end

  test "KamalProxyAdapter#unpublish removes the service" do
    ssh = FakeSsh.new
    result = Edge.for(server("kamal_proxy"), ssh: ssh).unpublish(domain: "a.com")
    assert_equal "kamal_proxy", result[:edge]
    assert ssh.commands.any? { |c| c.include?("kamal-proxy remove") },
           "expected a remove command; got #{ssh.commands.inspect}"
  end

  test "KamalProxyAdapter raises a legible error when kamal-proxy fails" do
    ssh = FakeSsh.new(success: false)
    assert_raises(Edge::KamalProxyAdapter::Error) do
      Edge.for(server("kamal_proxy"), ssh: ssh).publish(domain: "a.com", upstream: "x:3000")
    end
  end
end
