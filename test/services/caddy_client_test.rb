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

  def test_upsert_route_adopts_a_legacy_route_in_place
    config = {
      "apps" => { "http" => { "servers" => { "srv0" => { "routes" => [
        { "match" => [ { "host" => [ "example.com" ] } ],
          "handle" => [ { "handler" => "reverse_proxy", "upstreams" => [ { "dial" => "127.0.0.1:20000" } ] } ] },
        { "@id" => "unrelated", "match" => [ { "host" => [ "other.example.com" ] } ] }
      ] } } } }
    }
    loaded = nil
    client = CaddyClient.new(build_server)
    client.stub(:fetch_config, config) do
      client.stub(:load_config, ->(value) { loaded = value }) do
        result = client.live(domain: "example.com", upstream: "127.0.0.1:3000", server_name: "srv0")
        assert_equal "updated", result["action"]
      end
    end

    routes = loaded.dig("apps", "http", "servers", "srv0", "routes")
    assert_equal 2, routes.length
    assert_equal "conductor-route-example-com", routes.first["@id"]
    assert_equal "127.0.0.1:3000", routes.first.dig("handle", 0, "upstreams", 0, "dial")
  end

  def test_maintenance_route_returns_503_without_an_upstream
    ssh = FakeSsh.new([ { stdout: "{}" }, { stdout: "" } ])
    client = CaddyClient.new(build_server, ssh_connection: ssh)

    client.maintenance(domain: "example.com", message: "planned")

    loaded = ssh.commands.last
    assert_includes loaded, "static_response"
    assert_includes loaded, "503"
    assert_includes loaded, "planned"
    refute_includes loaded, "reverse_proxy"
  end

  def test_managed_domains_for_upstream_finds_apex_alias_and_wildcard_routes
    config = {
      "apps" => { "http" => { "servers" => { "srv0" => { "routes" => [
        { "@id" => "conductor-route-example-com", "match" => [ { "host" => [ "example.com" ] } ],
          "handle" => [ { "handler" => "reverse_proxy", "upstreams" => [ { "dial" => "127.0.0.1:3000" } ] } ] },
        { "@id" => "conductor-route-www-example-com", "match" => [ { "host" => [ "www.example.com" ] } ],
          "handle" => [ { "handler" => "reverse_proxy", "upstreams" => [ { "dial" => "127.0.0.1:3000" } ] } ] },
        { "@id" => "conductor-route-wildcard-example-com", "match" => [ { "host" => [ "*.example.com" ] } ],
          "handle" => [ { "handler" => "reverse_proxy", "upstreams" => [ { "dial" => "127.0.0.1:3000" } ] } ] },
        { "@id" => "conductor-route-other-com", "match" => [ { "host" => [ "other.com" ] } ],
          "handle" => [ { "handler" => "reverse_proxy", "upstreams" => [ { "dial" => "127.0.0.1:4000" } ] } ] }
      ] } } } }
    }

    client = CaddyClient.new(build_server, ssh_connection: FakeSsh.new([ { stdout: JSON.generate(config) } ]))

    assert_equal [ "example.com", "www.example.com", "*.example.com" ],
                 client.managed_domains_for_upstream("127.0.0.1:3000")
  end

  # An apex and its wildcard are different routes to the same app; their ids must
  # differ so adding *.domain doesn't overwrite the apex route (and vice versa).
  def test_apex_and_wildcard_get_distinct_route_ids
    client = CaddyClient.new(build_server)
    apex = client.send(:route_id_for, "zone-a.example")
    wild = client.send(:route_id_for, "*.zone-a.example")

    assert_equal "conductor-route-zone-a-example", apex
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

    res = client.enable_on_demand_tls(subject: "*.zone-a.example", ask_url: "http://127.0.0.1:9080/caddy/ask")

    assert_equal "*.zone-a.example", res["subject"]
    assert res["on_demand"]
    assert_equal 2, ssh.commands.size
    loaded = ssh.commands.last
    assert_includes loaded, "/load"
    # Caddy 2.8+ ask gate is a `permission` module — not the pre-2.8 bare `ask`.
    assert_includes loaded, "permission"
    assert_includes loaded, "module"
    assert_includes loaded, "127.0.0.1:9080/caddy/ask"
    assert_includes loaded, "on_demand"
    assert_includes loaded, ".zone-a.example" # `*` is shell-escaped, the zone tail is not
  end

  # THE PERMISSION ENDPOINT IS GLOBAL, and only the POLICIES are per-zone. Enabling
  # on-demand TLS for a second zone silently re-pointed the first zone's issuance
  # gate at the second zone's app, which then answered 404/EOF for every name — so
  # every subdomain certificate was refused, on a zone nobody had touched.
  def test_enable_on_demand_tls_refuses_to_repoint_another_zones_gate
    existing = {
      "apps" => { "tls" => { "automation" => {
        "on_demand" => { "permission" => { "module" => "http", "endpoint" => "http://127.0.0.1:9080/caddy/ask" } },
        "policies" => [ { "subjects" => [ "*.zone-a.example" ], "on_demand" => true } ]
      } } }
    }
    ssh = FakeSsh.new([ { stdout: JSON.generate(existing) } ])
    client = CaddyClient.new(build_server, ssh_connection: ssh)

    error = assert_raises(CaddyClient::Error) do
      client.enable_on_demand_tls(subject: "*.other.example", ask_url: "http://127.0.0.1:9070/caddy/ask")
    end

    assert_match(/9080/, error.message, "the message must name the endpoint already in use")
    assert_match(/zone-a\.example/, error.message, "and the zone that depends on it")
    assert_equal 1, ssh.commands.size, "nothing may be written when the call is refused"
  end

  # The list is read as "these are the zones I would break", so a wrong one is worse
  # than none: a policy that is not on-demand does not use this gate, and a policy
  # with no subjects is a catch-all that uses it for everything.
  def test_dependent_zone_list_counts_only_on_demand_policies_and_catch_alls
    existing = {
      "apps" => { "tls" => { "automation" => {
        "on_demand" => { "permission" => { "module" => "http", "endpoint" => "http://127.0.0.1:9080/caddy/ask" } },
        "policies" => [
          { "subjects" => [ "*.not-on-demand.example" ] },
          { "subjects" => [ "*.zone-a.example" ], "on_demand" => true },
          { "on_demand" => true }
        ]
      } } }
    }
    ssh = FakeSsh.new([ { stdout: JSON.generate(existing) } ])
    client = CaddyClient.new(build_server, ssh_connection: ssh)

    error = assert_raises(CaddyClient::Error) do
      client.enable_on_demand_tls(subject: "*.new.example", ask_url: "http://127.0.0.1:9070/caddy/ask")
    end

    assert_includes error.message, "*.zone-a.example"
    assert_includes error.message, "catch-all"
    refute_includes error.message, "not-on-demand", "a policy that is not on-demand does not use this gate"
  end

  # Re-running for the SAME endpoint is still idempotent — that is the ordinary case
  # and must not start failing.
  def test_enable_on_demand_tls_allows_a_second_zone_on_the_same_gate
    existing = {
      "apps" => { "tls" => { "automation" => {
        "on_demand" => { "permission" => { "module" => "http", "endpoint" => "http://127.0.0.1:9080/caddy/ask" } },
        "policies" => [ { "subjects" => [ "*.zone-a.example" ], "on_demand" => true } ]
      } } }
    }
    ssh = FakeSsh.new([ { stdout: JSON.generate(existing) }, { stdout: "" } ])
    client = CaddyClient.new(build_server, ssh_connection: ssh)

    res = client.enable_on_demand_tls(subject: "*.other.example", ask_url: "http://127.0.0.1:9080/caddy/ask")

    assert res["on_demand"]
    assert_includes ssh.commands.last, ".zone-a.example", "the existing zone's policy must survive"
  end

  # The escape hatch exists for the case the operator IS re-pointing deliberately —
  # repairing a gate that a previous overwrite already broke, for instance.
  def test_enable_on_demand_tls_can_repoint_when_asked_explicitly
    existing = {
      "apps" => { "tls" => { "automation" => {
        "on_demand" => { "permission" => { "module" => "http", "endpoint" => "http://127.0.0.1:9070/caddy/ask" } },
        "policies" => [ { "subjects" => [ "*.zone-a.example" ], "on_demand" => true } ]
      } } }
    }
    ssh = FakeSsh.new([ { stdout: JSON.generate(existing) }, { stdout: "" } ])
    client = CaddyClient.new(build_server, ssh_connection: ssh)

    res = client.enable_on_demand_tls(subject: "*.zone-a.example", ask_url: "http://127.0.0.1:9080/caddy/ask",
                                      repoint_shared_gate: true)

    assert_equal "http://127.0.0.1:9080/caddy/ask", res["ask_url"]
    assert_includes ssh.commands.last, "9080"
  end

  def test_enable_on_demand_tls_is_idempotent_and_keeps_other_zones
    existing = {
      "apps" => { "tls" => { "automation" => { "policies" => [
        { "subjects" => [ "*.other.com" ], "on_demand" => true },
        { "subjects" => [ "*.zone-a.example" ], "on_demand" => true }
      ] } } }
    }
    ssh = FakeSsh.new([
      { stdout: JSON.generate(existing) }, # fetch_config
      { stdout: "" }                       # load_config
    ])
    client = CaddyClient.new(build_server, ssh_connection: ssh)

    client.enable_on_demand_tls(subject: "*.zone-a.example", ask_url: "http://127.0.0.1:9080/caddy/ask")

    loaded = ssh.commands.last
    assert_includes loaded, ".other.com" # a different app's policy is preserved
    assert_equal 1, loaded.scan(".zone-a.example").size, "the same-subject policy must be replaced, not duplicated"
  end

  def test_enable_on_demand_tls_rejects_a_non_http_ask_url
    client = CaddyClient.new(build_server, ssh_connection: FakeSsh.new([]))
    assert_raises(CaddyClient::Error) do
      client.enable_on_demand_tls(subject: "*.zone-a.example", ask_url: "not-a-url")
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
