require "test_helper"

class CaddyClientTest < ActiveSupport::TestCase
  FakeSsh = Struct.new(:responses, :error) do
    attr_reader :commands

    def initialize(responses)
      super(responses, nil)
      @commands = []
    end

    def execute_with_status(command)
      @commands << command
      response = responses.shift || {}
      self.error = response[:error]
      {
        success: response.fetch(:success, true),
        exit_code: response.fetch(:exit_code, response.fetch(:success, true) ? 0 : 1),
        stdout: response[:stdout].to_s,
        stderr: response[:stderr].to_s,
        output: response[:stdout].to_s.presence || response[:stderr].to_s.presence
      }
    end
  end

  def test_fetch_managed_routes_only_returns_conductor_routes
    config = {
      "apps" => {
        "http" => {
          "servers" => {
            "srv0" => {
              "routes" => [
                {
                  "@id" => "conductor-route-example-com",
                  "match" => [ { "host" => [ "example.com" ] } ],
                  "handle" => [ { "handler" => "reverse_proxy", "upstreams" => [ { "dial" => "127.0.0.1:3000" } ] } ],
                  "terminal" => true
                },
                {
                  "@id" => "manual-route",
                  "match" => [ { "host" => [ "manual.example.com" ] } ],
                  "handle" => [ { "handler" => "reverse_proxy", "upstreams" => [ { "dial" => "127.0.0.1:4000" } ] } ]
                }
              ]
            }
          }
        }
      }
    }

    client = CaddyClient.new(build_server, ssh_connection: FakeSsh.new([ { stdout: JSON.generate(config) } ]))
    routes = client.fetch_managed_routes

    assert_equal 1, routes.size
    assert_equal "example.com", routes.first["domain"]
    assert_equal "conductor-route-example-com", routes.first["route_id"]
  end

  def test_upsert_route_loads_a_minimal_config_when_caddy_is_blank
    ssh = FakeSsh.new([
      { stdout: "{}" },
      { stdout: "" }
    ])

    client = CaddyClient.new(build_server, ssh_connection: ssh)
    route = client.upsert_route(domain: "example.com", upstream: "127.0.0.1:3000")

    assert_equal "created", route["action"]
    assert_equal "example.com", route["domain"]
    assert_equal 2, ssh.commands.size
    assert_includes ssh.commands.last, "/load"
    assert_includes ssh.commands.last, "conductor-route-example-com"
    assert_includes ssh.commands.last, "127.0.0.1:3000"
  end

  # An apex and its wildcard are different routes to the same app; their ids must
  # differ so adding *.domain doesn't overwrite the apex route (and vice versa).
  def test_apex_and_wildcard_get_distinct_route_ids
    client = CaddyClient.new(build_server)
    apex = client.send(:route_id_for, "calm.page")
    wild = client.send(:route_id_for, "*.calm.page")

    assert_equal "conductor-route-calm-page", apex
    refute_equal apex, wild, "apex and wildcard must not collide into one route id"
    assert_includes wild, "wildcard"
  end

  def test_remove_route_deletes_a_managed_route_by_domain
    config = {
      "apps" => {
        "http" => {
          "servers" => {
            "srv0" => {
              "routes" => [
                {
                  "@id" => "conductor-route-example-com",
                  "match" => [ { "host" => [ "example.com" ] } ],
                  "handle" => [ { "handler" => "reverse_proxy", "upstreams" => [ { "dial" => "127.0.0.1:3000" } ] } ]
                }
              ]
            }
          }
        }
      }
    }

    ssh = FakeSsh.new([
      { stdout: JSON.generate(config) },
      { stdout: "" }
    ])

    client = CaddyClient.new(build_server, ssh_connection: ssh)
    route = client.remove_route("example.com")

    assert_equal "removed", route["action"]
    assert_equal "conductor-route-example-com", route["route_id"]
    refute_includes ssh.commands.last, "example.com\\\""
  end

  def test_enable_on_demand_tls_writes_the_permission_gate_and_a_scoped_policy
    ssh = FakeSsh.new([
      { stdout: "{}" }, # fetch_config
      { stdout: "" }    # load_config
    ])
    client = CaddyClient.new(build_server, ssh_connection: ssh)

    res = client.enable_on_demand_tls(subject: "*.calm.page", ask_url: "http://127.0.0.1:9080/caddy/ask")

    assert_equal "*.calm.page", res["subject"]
    assert res["on_demand"]
    assert_equal 2, ssh.commands.size
    loaded = ssh.commands.last
    assert_includes loaded, "/load"
    # Caddy 2.8+ ask gate is a `permission` module — not the pre-2.8 bare `ask`.
    assert_includes loaded, "permission"
    assert_includes loaded, "module"
    assert_includes loaded, "127.0.0.1:9080/caddy/ask"
    assert_includes loaded, "on_demand"
    assert_includes loaded, ".calm.page" # `*` is shell-escaped, the zone tail is not
  end

  def test_enable_on_demand_tls_is_idempotent_and_keeps_other_zones
    existing = {
      "apps" => { "tls" => { "automation" => { "policies" => [
        { "subjects" => [ "*.other.com" ], "on_demand" => true },
        { "subjects" => [ "*.calm.page" ], "on_demand" => true }
      ] } } }
    }
    ssh = FakeSsh.new([
      { stdout: JSON.generate(existing) }, # fetch_config
      { stdout: "" }                       # load_config
    ])
    client = CaddyClient.new(build_server, ssh_connection: ssh)

    client.enable_on_demand_tls(subject: "*.calm.page", ask_url: "http://127.0.0.1:9080/caddy/ask")

    loaded = ssh.commands.last
    assert_includes loaded, ".other.com" # a different app's policy is preserved
    assert_equal 1, loaded.scan(".calm.page").size, "the same-subject policy must be replaced, not duplicated"
  end

  def test_enable_on_demand_tls_rejects_a_non_http_ask_url
    client = CaddyClient.new(build_server, ssh_connection: FakeSsh.new([]))
    assert_raises(CaddyClient::Error) do
      client.enable_on_demand_tls(subject: "*.calm.page", ask_url: "not-a-url")
    end
  end

  private

  def build_server
    server = Server.new(
      name: "edge-1",
      status: "online",
      ip_address: "203.0.113.10",
      ssh_user: "deploy"
    )
    server.define_singleton_method(:ssh_configured?) { true }
    server
  end
end
