require "test_helper"

class CaddyCutoverTest < ActiveSupport::TestCase
  class FakeCaddy
    attr_reader :live_calls

    def initialize(routes)
      @routes = routes
      @live_calls = []
    end

    def fetch_routes = @routes

    def live(domain:, upstream:, server_name: nil)
      @live_calls << [ domain, upstream ]
      route = @routes.find do |entry|
        entry["domain"] == domain && (server_name.nil? || entry["server_name"] == server_name)
      end
      route ? route["upstream"] = upstream : @routes << { "domain" => domain, "upstream" => upstream }
    end
  end

  setup do
    user = User.create!(email: "cutover@example.com")
    org = Organization.create_for(user, name: "Cutover")
    server = org.servers.create!(name: "caddy", edge_type: "caddy", status: "online")
    @app = org.apps.create!(name: "App", slug: "app", server: server,
                            domain: "example.com", port: 3000)
  end

  test "captures and reconciles apex, wildcard, and no-id aliases" do
    routes = [
      { "domain" => "example.com", "upstream" => "127.0.0.1:3000", "route_id" => nil },
      { "domain" => "*.example.com", "upstream" => "127.0.0.1:20000", "route_id" => nil },
      { "domain" => "www.example.com", "upstream" => "127.0.0.1:3000", "route_id" => nil },
      { "domain" => "other.example.net", "upstream" => "127.0.0.1:4000", "route_id" => nil }
    ]
    caddy = FakeCaddy.new(routes)
    cutover = CaddyCutover.new(@app, client: caddy)

    assert_raises(CaddyCutover::Error, /ambiguous Caddy hostname ownership/) do
      cutover.prepare!
    end

    routes[1]["upstream"] = "127.0.0.1:3000"
    cutover.prepare!
    result = cutover.reconcile!

    assert_equal [
      [ "example.com", "127.0.0.1:3000" ],
      [ "*.example.com", "127.0.0.1:3000" ],
      [ "www.example.com", "127.0.0.1:3000" ],
    ], caddy.live_calls
    assert_empty result[:stale]
  end

  test "fails closed when an unrelated route shares the fixed port" do
    routes = [
      { "domain" => "example.com", "upstream" => "127.0.0.1:3000", "route_id" => nil },
      { "domain" => "other.example.net", "upstream" => "127.0.0.1:3000", "route_id" => nil }
    ]

    assert_raises(CaddyCutover::Error, /ambiguous Caddy port ownership/) do
      CaddyCutover.new(@app, client: FakeCaddy.new(routes)).prepare!
    end
  end

  test "always includes the primary domain when no route exists yet" do
    caddy = FakeCaddy.new([])
    cutover = CaddyCutover.new(@app, client: caddy)

    cutover.prepare!
    assert_equal [ [ "example.com", "127.0.0.1:3000" ] ], begin
      cutover.reconcile!
      caddy.live_calls
    end
  end
end
