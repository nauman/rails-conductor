require "test_helper"

class EdgeOperationsTest < ActiveSupport::TestCase
  class FakeCaddy
    attr_reader :calls

    def initialize = @calls = []
    def fetch_managed_routes = (@calls << :routes; [])
    def maintenance(domain:, message:) = (@calls << [ :maintenance, domain, message ]; { action: "maintenance" })
    def live(domain:, upstream:) = (@calls << [ :live, domain, upstream ]; { action: "updated" })
  end

  setup do
    user = User.create!(email: "edge-ops@example.com")
    @org = Organization.create_for(user, name: "Edge Ops")
    @key = SshKey.create!(name: "edge-ops-key", private_key: valid_private_key, organization: @org)
    @caddy = @org.servers.create!(name: "caddy", status: "online", ip_address: "10.0.0.2",
                                  ssh_key: @key, edge_type: "caddy")
    @proxy = @org.servers.create!(name: "proxy", status: "online", ip_address: "10.0.0.3",
                                  ssh_key: @key, edge_type: "kamal_proxy")
    @app = @org.apps.create!(name: "App", slug: "app", server: @caddy,
                             deploy_method: "kamal", domain: "app.example.com", port: 9000,
                             repository_url: "https://example.com/app.git", status: "running",
                             container_status: "running", last_status_check_at: Time.current)
  end

  test "Caddy proxy inspection uses Caddy and never invokes Kamal proxy" do
    caddy = FakeCaddy.new
    result = EdgeOperations.new(@app, caddy_client: caddy).proxy(:inspect)

    assert_equal [], result
    assert_equal [ :routes ], caddy.calls
  end

  test "Caddy proxy reconciliation restores the desired route through Caddy" do
    caddy = FakeCaddy.new
    EdgeOperations.new(@app, caddy_client: caddy).proxy(:reconcile)

    assert_equal [ :live, "app.example.com", "127.0.0.1:9000" ], caddy.calls.last
  end

  test "Caddy maintenance and live change only the app route" do
    caddy = FakeCaddy.new
    ops = EdgeOperations.new(@app, caddy_client: caddy)

    ops.maintenance!(message: "planned")
    ops.live!

    assert_equal [
      [ :maintenance, "app.example.com", "planned" ],
      [ :live, "app.example.com", "127.0.0.1:9000" ]
    ], caddy.calls
  end

  test "Caddy redeploy enters Conductor's deployment transaction" do
    called = false
    @app.stub(:start_deployment!, ->(**) { called = true; [ nil, :started, nil ] }) do
      assert_equal :started, EdgeOperations.new(@app).redeploy!
    end
    assert called
  end

  test "Caddy operations do not expose raw Kamal proxy or redeploy commands" do
    ops = EdgeOperations.new(@app)

    assert_raises(EdgeOperations::UnsupportedOperation) { ops.proxy(:restart) }
  end

  test "Caddy live refuses to restore an unhealthy app" do
    caddy = FakeCaddy.new
    @app.update_columns(status: "stopped", container_status: "exited")
    assert_raises(EdgeOperations::UnsupportedOperation) { EdgeOperations.new(@app, caddy_client: caddy).live! }
    assert_empty caddy.calls
  end

  test "Caddy live refuses to invent a host upstream from the runtime port" do
    @app.update_column(:port, nil)
    caddy = FakeCaddy.new

    error = assert_raises(EdgeOperations::UnsupportedOperation) do
      EdgeOperations.new(@app, caddy_client: caddy).live!
    end

    assert_match(/host-published port is not recorded/, error.message)
    assert_empty caddy.calls
  end

  test "Kamal-proxy edge keeps proxy operations in Kamal" do
    app = @org.apps.create!(name: "Proxy App", slug: "proxy-app", server: @proxy,
                            deploy_method: "kamal", domain: "proxy.example.com",
                            repository_url: "https://example.com/proxy.git")
    runner = Object.new
    calls = []
    runner.define_singleton_method(:proxy) { |action| calls << action; :ok }

    assert_equal :ok, EdgeOperations.new(app, kamal_edge: runner).proxy(:restart)
    assert_equal [ :restart ], calls
  end
end
