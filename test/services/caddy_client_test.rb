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
