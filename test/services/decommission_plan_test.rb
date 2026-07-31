require "test_helper"

# The discovery-first report: given an app + the box it's being retired from,
# SSH-inspect the REAL footprint (containers / port holder / native / dedicated
# DB / control-plane records) and raise the right findings — mutating nothing.
# Fake SSH returns canned docker/ss/systemctl output (mirrors the DatabaseReplicator
# and StopAppTool fake-SSH idioms).
class DecommissionPlanTest < ActiveSupport::TestCase
  # Answers each probe from a canned map keyed by a substring of the command.
  class FakeSsh
    attr_reader :commands

    def initialize(responses = {})
      @responses = responses
      @commands = []
    end

    def execute_with_status(cmd)
      @commands << cmd
      # Shellwords escapes `=` (label\=service\=…); match on the unescaped form,
      # and let the MOST specific (longest) matching needle win.
      normalized = cmd.delete("\\")
      match = @responses.select { |needle, _| normalized.include?(needle) }
                        .max_by { |needle, _| needle.length }
      { success: true, stdout: match&.last.to_s, stderr: "" }
    end

    def error = nil
  end

  setup do
    user = User.create!(email: "retire-plan@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @home = @org.servers.create!(name: "new-box", status: "online", ip_address: "10.0.0.9", ssh_key: @key, ssh_user: "deploy")
    @old  = @org.servers.create!(name: "old-box", status: "online", ip_address: "10.0.0.1", ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @home, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", port: 3000)
  end

  def plan(ssh:, server: @old)
    DecommissionPlan.new(app: @app, server: server, ssh: ssh).call
  end

  test "reports running/exited containers found by the service label" do
    ssh = FakeSsh.new(
      "label=service=appone" => "appone-web-abc\tUp 3 hours\nappone-web-old\tExited (0) 2 days ago\n"
    )
    containers = plan(ssh: ssh).containers

    names = containers.map { |c| c[:name] }
    assert_includes names, "appone-web-abc"
    assert_includes names, "appone-web-old"
    assert_equal "running", containers.find { |c| c[:name] == "appone-web-abc" }[:state]
    assert_equal "exited",  containers.find { |c| c[:name] == "appone-web-old" }[:state]
  end

  test "flags a native process holding the port instead of docker (the key surprise)" do
    ssh = FakeSsh.new(
      "sport = :3000" => %(LISTEN 0 1024 0.0.0.0:3000 0.0.0.0:* users:(("puma",pid=999,fd=7)))
    )
    p = plan(ssh: ssh)

    assert_equal "native", p.port_holder[:kind]
    assert_equal "puma", p.port_holder[:process]
    assert(p.findings.any? { |f| f[:code] == "native_vs_docker_port" })
  end

  test "docker-proxy holding the port is the expected case (no native finding)" do
    ssh = FakeSsh.new(
      "sport = :3000" => %(LISTEN 0 4096 127.0.0.1:3000 0.0.0.0:* users:(("docker-proxy",pid=1234,fd=4)))
    )
    p = plan(ssh: ssh)

    assert_equal "docker", p.port_holder[:kind]
    refute(p.findings.any? { |f| f[:code] == "native_vs_docker_port" })
  end

  test "raises the docker+native duplication finding when both claim the service" do
    ssh = FakeSsh.new(
      "label=service=appone"  => "appone-web-abc\tUp 3 hours\n",
      "systemctl --user"      => "appone-server.service loaded active running\n",
      "sport = :3000"         => %(users:(("puma",pid=1)))
    )
    p = plan(ssh: ssh)

    assert p.native.any?, "native footprint discovered"
    assert(p.findings.any? { |f| f[:code] == "docker_native_duplication" && f[:severity] == "critical" })
  end

  test "flags a stale exited container still present" do
    ssh = FakeSsh.new(
      "label=service=appone" => "appone-web-old\tExited (0) 5 days ago\n"
    )
    p = plan(ssh: ssh)
    assert(p.findings.any? { |f| f[:code] == "stale_idle_container" })
  end

  test "flags retire-before-move when the app is still homed on this box" do
    ssh = FakeSsh.new
    # Retire the app's OWN home server — the orphaning case.
    p = DecommissionPlan.new(app: @app, server: @home, ssh: ssh).call

    assert p.records[:is_app_home]
    assert(p.findings.any? { |f| f[:code] == "retire_before_move" && f[:severity] == "critical" })
  end

  test "discovers the dedicated DB container + volume on the box" do
    ssh = FakeSsh.new(
      "--filter name=#{@app.dedicated_db_container_name}"          => "#{@app.dedicated_db_container_name}\tUp 2 hours\n",
      "--filter name=#{@app.dedicated_db_container_name}-data"     => "#{@app.dedicated_db_container_name}-data\n"
    )
    dedicated = plan(ssh: ssh).dedicated_db

    assert dedicated[:present]
    assert_equal "#{@app.dedicated_db_container_name}", dedicated[:container_name]
    assert dedicated[:volume_present]
  end

  test "a shared-cluster DB record is flagged for a human, never auto-dropped" do
    @app.update!(database_mode: "shared")
    cluster = @org.database_clusters.create!(name: "shared", container_name: "pg-shared",
                                             admin_username: "postgres", server: @old)
    @org.databases.create!(name: "appone_prod", username: "appone", database_cluster: cluster, app: @app, status: "active")

    p = plan(ssh: FakeSsh.new)
    finding = p.findings.find { |f| f[:code] == "shared_cluster_db" }
    assert finding, "shared-cluster DB copy is surfaced"
    assert_match(/pg-shared/, finding[:message])
  end

  test "to_h is serializable and mutates nothing" do
    ssh = FakeSsh.new("label=service=appone" => "appone-web\tUp 1 hour\n")
    h = plan(ssh: ssh).to_h

    assert_equal "appone", h[:app]
    assert_equal "old-box", h[:server]
    assert h.key?(:containers) && h.key?(:port_holder) && h.key?(:findings)
    assert JSON.generate(h) # serializable
    assert_equal 0, Decommission.count, "the plan persists nothing"
  end
end
