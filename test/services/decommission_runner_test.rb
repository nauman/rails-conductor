require "test_helper"

# The teardown engine: runs the phases in order (containers → dedicated_db →
# records), records the audit trail, refuses to retire the app's live home, and
# NEVER touches a shared cluster's DB. The ENGINE is exercised with an injected
# deps object; the real FleetDeps command shape is asserted with a fake SSH
# (mirrors AppTransferRunner + DatabaseReplicator idioms).
class DecommissionRunnerTest < ActiveSupport::TestCase
  # Records phase calls — used to assert ordering without touching infrastructure.
  class FakeDeps
    attr_reader :calls
    def initialize = @calls = []
    def remove_containers   = @calls << :containers
    def remove_dedicated_db = @calls << :dedicated_db
    def clean_records       = @calls << :records
  end

  # A canned discovery report so the engine tests never SSH.
  class FakePlan
    def to_h = { app: "appone", findings: findings }
    def findings = [ { code: "native_vs_docker_port", severity: "warning", message: "native holds the port" } ]
  end

  # Records every command; returns success (mirrors DatabaseReplicator::FakeSsh).
  class FakeSsh
    attr_reader :commands
    def initialize = @commands = []
    def execute_with_status(cmd) = (@commands << cmd; { success: true, stdout: "", stderr: "" })
    def error = nil
  end

  setup do
    user = User.create!(email: "retire-runner@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @home = @org.servers.create!(name: "new-box", status: "online", ip_address: "10.0.0.9", ssh_key: @key, ssh_user: "deploy")
    @old  = @org.servers.create!(name: "old-box", status: "online", ip_address: "10.0.0.1", ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @home, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", port: 3000)
  end

  def decommission(server: @old)
    Decommission.create!(app: @app, organization: @org, server: server, status: "pending")
  end

  test "runs every phase in order and records success + audit log" do
    deps = FakeDeps.new
    d = decommission
    assert DecommissionRunner.new(d, deps: deps, plan: FakePlan.new).run

    assert_equal %i[containers dedicated_db records], deps.calls
    assert d.reload.succeeded?
    assert_equal "records", d.phase
    assert d.finished_at.present?
    assert_includes d.log, "→ containers"
    assert_includes d.log, "✓ records"
  end

  test "records the discovery findings into #findings before executing" do
    d = decommission
    DecommissionRunner.new(d, deps: FakeDeps.new, plan: FakePlan.new).run

    assert_equal "native holds the port", d.reload.findings_data["findings"].first["message"]
    assert_includes d.log, "[warning] native holds the port"
  end

  test "refuses when the server is still the app's home (would orphan the live app)" do
    deps = FakeDeps.new
    d = decommission(server: @home) # the app's own home
    refute DecommissionRunner.new(d, deps: deps, plan: FakePlan.new).run

    assert_empty deps.calls, "no phase runs when the retire is refused"
    assert d.reload.failed?
    assert_match(/orphan|move it/i, d.log)
  end

  test "folds decommission learnings into the app's runbook on success" do
    d = decommission
    DecommissionRunner.new(d, deps: FakeDeps.new, plan: FakePlan.new).run

    assert_match(/Decommission learnings/i, @app.reload.deploy_runbook.to_s)
    assert_match(/ss -tlnp/, @app.deploy_runbook.to_s, "the fired gotcha's note is folded in")
  end

  # --- FleetDeps command shape (real deps, fake SSH) -------------------------

  test "FleetDeps removes containers scoped to the service label — never a broad prune" do
    ssh = FakeSsh.new
    deps = DecommissionRunner::FleetDeps.new(decommission, ssh: ssh)
    deps.remove_containers

    joined = ssh.commands.join("\n").delete("\\") # Shellwords escapes the `=`
    assert_match(/docker rm -f/, joined)
    assert_match(/label=service=appone/, joined)
    refute_match(/prune/, joined, "never a broad prune")
    refute_match(/docker rm -f \$\(docker ps -aq\)\s*$/, joined, "never an unfiltered rm-all")
  end

  test "FleetDeps removes the app's OWN dedicated DB container + volume" do
    ssh = FakeSsh.new
    DecommissionRunner::FleetDeps.new(decommission, ssh: ssh).remove_dedicated_db

    joined = ssh.commands.join("\n")
    assert_match(/docker rm -f .*#{@app.dedicated_db_container_name}/, joined)
    assert_match(/docker volume rm .*#{@app.dedicated_db_volume}/, joined)
  end

  test "FleetDeps never drops a shared-cluster DB" do
    @app.update!(database_mode: "shared")
    ssh = FakeSsh.new
    d = decommission
    DecommissionRunner::FleetDeps.new(d, ssh: ssh).remove_dedicated_db

    assert_empty ssh.commands, "shared-cluster app removes no DB container/volume over SSH"
    refute_match(/DROP DATABASE/i, ssh.commands.join)
    assert_match(/shared-cluster/i, d.reload.log)
  end

  test "FleetDeps#clean_records destroys only THIS box's records, not the live home's" do
    old_cluster = @org.database_clusters.create!(name: "old", container_name: "appone-db",
                                                 admin_username: "postgres", server: @old)
    new_cluster = @org.database_clusters.create!(name: "new", container_name: "appone-db",
                                                 admin_username: "postgres", server: @home)
    on_old = @org.databases.create!(name: "appone_prod", username: "u", database_cluster: old_cluster, app: @app, status: "active")
    on_new = @org.databases.create!(name: "appone_prod", username: "u", database_cluster: new_cluster, app: @app, status: "active")

    DecommissionRunner::FleetDeps.new(decommission, ssh: FakeSsh.new).clean_records

    refute Database.exists?(on_old.id), "the retiring box's record is destroyed"
    assert Database.exists?(on_new.id), "the live home's record is untouched"
  end
end
