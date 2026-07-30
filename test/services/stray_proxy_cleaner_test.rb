require "test_helper"

class StrayProxyCleanerTest < ActiveSupport::TestCase
  # Matches queued responses by command substring, so the service can issue its
  # probes in any order without a brittle positional queue.
  class FakeSsh
    attr_reader :commands
    def initialize(map)
      @map = map
      @commands = []
    end

    def execute_with_status(command)
      @commands << command
      key = @map.keys.find { |k| command.include?(k) }
      r = key ? @map[key] : {}
      out = r[:stdout].to_s
      { success: r.fetch(:success, true), exit_code: r.fetch(:success, true) ? 0 : 1,
        stdout: out, stderr: "", output: out }
    end
  end

  setup do
    user = User.create!(email: "spc@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @caddy = @org.servers.create!(name: "SSD", status: "online", ip_address: "10.0.0.5", ssh_key: key, edge_type: "caddy")
    @proxybox = @org.servers.create!(name: "pave", status: "online", ip_address: "10.0.0.6", ssh_key: key, edge_type: "kamal_proxy")
  end

  HEADER = "Service  Host  Path  Target  State  TLS\n".freeze

  def ssh_for(present: true, routes: HEADER, ports: "", rm: true)
    FakeSsh.new(
      "docker ps -aq"    => { stdout: present ? "abc123\n" : "" },
      "kamal-proxy ls"   => { stdout: routes },
      "docker port"      => { stdout: ports },
      "docker rm -f"     => { success: rm }
    )
  end

  test "inert kamal-proxy on a host-Caddy box is reported safe, then removed on confirm" do
    report = StrayProxyCleaner.new(@caddy, ssh: ssh_for).inspect_only
    assert report.safe
    refute report.removed
    assert_match(/inert zombie/i, report.message)

    ssh = ssh_for
    done = StrayProxyCleaner.new(@caddy, ssh: ssh).remove!
    assert done.safe
    assert done.removed
    assert ssh.commands.any? { |c| c.include?("docker rm -f") && c.include?("kamal-proxy") }
  end

  test "REFUSES when kamal-proxy still routes a service (would break apps)" do
    routes = HEADER + "inventlist  inventlist.com  /  10.0.0.9:3000  running  yes\n"
    res = StrayProxyCleaner.new(@caddy, ssh: ssh_for(routes: routes)).remove!
    refute res.safe
    refute res.removed
    assert_match(/still routes/i, res.message)
  end

  test "REFUSES when kamal-proxy still binds host ports" do
    res = StrayProxyCleaner.new(@caddy, ssh: ssh_for(ports: "80/tcp -> 0.0.0.0:80\n")).inspect_only
    refute res.safe
    assert_match(/binds/i, res.message)
  end

  test "REFUSES on a non-Caddy (real kamal-proxy) box" do
    res = StrayProxyCleaner.new(@proxybox, ssh: ssh_for).remove!
    refute res.safe
    refute res.removed
    assert_match(/not a host-Caddy box/i, res.message)
  end

  test "no kamal-proxy container present is a clean no-op" do
    res = StrayProxyCleaner.new(@caddy, ssh: ssh_for(present: false)).inspect_only
    refute res.safe
    assert_match(/nothing to remove/i, res.message)
  end
end
