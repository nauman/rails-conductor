require "test_helper"

# A docker deploy replaces the container, so any edge that routes to a CONTAINER
# (kamal-proxy) must be repointed or it keeps serving the removed one — a 502
# under a green "succeeded". Confirmed in production on Starrrs (deployment 215).
class AppDeployerEdgeTest < ActiveSupport::TestCase
  # Records the commands it is asked to run so we can assert on the republish.
  class FakeSsh
    attr_reader :commands

    # Real `kamal-proxy ls` output: ANSI colour + a header row.
    DEFAULT_LS = "\e[1mService      Host          Target             State    TLS\e[0m\n" \
                 "starrrs-web  starrrs.com   15c72f2e2f9e:3000  running  yes\n".freeze

    def initialize(list_output: DEFAULT_LS)
      @commands = []
      @list_output = list_output
    end

    def execute_with_status(cmd)
      @commands << cmd
      # Only answers the REAL spelling — a wrong command gets empty output, so a
      # regression to `kamal-proxy list` fails these tests instead of passing.
      return { success: true, output: @list_output, stderr: "" } if cmd.include?("kamal-proxy ls")

      { success: true, output: "", stderr: "" }
    end
  end

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   edge_type: "kamal_proxy")
    @app = @org.apps.create!(name: "Starrrs", slug: "starrrs", server: @server,
                             deploy_method: "docker", domain: "starrrs.com", port: 3000,
                             repository_url: "https://github.com/x/y.git",
                             container_id: "166a73834701")
    @deployment = @app.deployments.create!(status: "deploying")
  end

  def republish(ssh)
    deployer = AppDeployer.new(@app, @deployment)
    deployer.stub(:ssh, ssh) { deployer.send(:republish_edge_route) }
  end

  test "repoints kamal-proxy at the NEW container after a docker deploy" do
    ssh = FakeSsh.new

    assert republish(ssh)

    publish = ssh.commands.find { |c| c.include?("kamal-proxy deploy") }
    assert publish, "expected the route to be republished"
    assert_includes publish, "166a73834701:3000", "must target the new container"
    assert_not_includes publish, "15c72f2e2f9e", "must not keep the removed container"
  end

  # The live route was created by `kamal deploy` and is keyed "starrrs-web".
  # Publishing under a host-derived key would leave two services claiming one
  # hostname instead of replacing the stale one.
  test "reuses the service that already serves the host, not a derived key" do
    ssh = FakeSsh.new

    republish(ssh)

    publish = ssh.commands.find { |c| c.include?("kamal-proxy deploy") }
    assert_includes publish, "starrrs-web"
    assert_not_includes publish, "starrrs-com"
  end

  # The proxy CLI is `ls`; StrayProxyCleaner uses the same. `list` silently
  # returns nothing, which would fall back to a derived key and create a SECOND
  # service for the host — the intermittent-502 failure this fix exists to avoid.
  test "queries the proxy with the real CLI spelling (ls, not list)" do
    ssh = FakeSsh.new
    republish(ssh)

    assert ssh.commands.any? { |c| c.include?("kamal-proxy ls") }, "must use `ls`"
    assert_not ssh.commands.any? { |c| c.match?(/kamal-proxy list\b/) }, "`list` is not a kamal-proxy command"
  end

  # The header row must not be mistaken for a route.
  test "ignores the header row and ANSI colour when resolving the service" do
    ssh = FakeSsh.new
    republish(ssh)

    publish = ssh.commands.find { |c| c.include?("kamal-proxy deploy") }
    assert_includes publish, "starrrs-web"
    assert_not_includes publish, "Service"
  end

  test "falls back to a derived key when the host has no existing route" do
    ssh = FakeSsh.new(list_output: "Service    Host       Target    State\nother-web  other.com  abc:3000  running\n")

    republish(ssh)

    publish = ssh.commands.find { |c| c.include?("kamal-proxy deploy") }
    assert_includes publish, "starrrs-com"
  end

  test "a caddy edge is left alone — it routes to host:port, not a container" do
    @app.server.update!(edge_type: "caddy")
    ssh = FakeSsh.new

    assert republish(ssh)
    assert_empty ssh.commands, "caddy needs no republish on container replacement"
  end

  test "an app with no domain is a no-op" do
    @app.update!(domain: nil)
    ssh = FakeSsh.new

    assert republish(ssh)
    assert_empty ssh.commands
  end

  # Better to fail the deploy loudly than to report success with a dead edge.
  test "a missing container id fails the step rather than reporting success" do
    @app.update!(container_id: nil)

    assert_not republish(FakeSsh.new)
  end
end
