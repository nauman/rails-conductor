require "test_helper"

# conductor_app action=retire — the invocable, discovery-first decommission.
# A bare call returns the discovery report + a dry_run audit record and mutates
# NOTHING; confirm:true executes the teardown. Requires the from-box explicitly
# and refuses to retire the app's live home. SSH is stubbed (StopAppTool idiom).
class RetireAppToolTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :server, :commands
    def initialize(server) = (@server = server; @commands = [])
    def execute_with_status(cmd) = (@commands << cmd; { success: true, stdout: "", stderr: "" })
    def error = nil
  end

  setup do
    @user = User.create!(email: "retire-tool@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @home = @org.servers.create!(name: "new-box", status: "online", ip_address: "10.0.0.9", ssh_key: key, ssh_user: "deploy")
    @old  = @org.servers.create!(name: "old-box", status: "online", ip_address: "10.0.0.1", ssh_key: key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @home, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", port: 3000)
  end

  def run_tool(**over)
    input = { "action" => "retire", "app_name" => "Appone", "from_server_name" => "old-box" }.merge(over.transform_keys(&:to_s))
    SshConnection.stub(:new, ->(srv) { FakeSsh.new(srv) }) do
      ConductorAppTool.new(user: @user).call(input)
    end
  end

  test "a bare call returns the discovery report and mutates nothing" do
    res = run_tool
    assert res.success?, res.error
    assert_equal "report_only", res.value[:status]
    assert_equal false, res.value[:action_taken]
    assert res.value.key?(:containers) && res.value.key?(:port_holder) && res.value.key?(:findings)
  end

  test "a bare call persists a dry_run Decommission record for the audit trail" do
    res = run_tool
    d = Decommission.find(res.value[:decommission_id])
    assert d.dry_run?
    assert_equal "pending", d.status, "report-only: never executed"
    assert d.findings.present?, "the findings are captured on the audit record"
  end

  test "confirm: true executes the runner and records the audit trail" do
    captured = nil
    fake_runner = Object.new
    def fake_runner.run = true
    stub = lambda do |decommission, **kw|
      captured = { decommission: decommission, kw: kw }
      fake_runner
    end
    res = nil
    DecommissionRunner.stub(:new, stub) do
      res = run_tool(confirm: true)
    end

    assert res.success?, res.error
    d = Decommission.find(res.value[:decommission_id])
    refute d.dry_run?, "a confirmed retire is a real run, not a dry run"
    assert_equal d, captured[:decommission], "the runner drove the persisted record"
    assert captured[:kw][:deps].is_a?(DecommissionRunner::FleetDeps), "wired with the real FleetDeps"
  end

  test "the from-server must be named explicitly" do
    res = SshConnection.stub(:new, ->(srv) { FakeSsh.new(srv) }) do
      ConductorAppTool.new(user: @user).call("action" => "retire", "app_name" => "Appone")
    end
    refute res.success?
    assert_match(/from_server/, res.error)
    assert_equal 0, Decommission.count
  end

  test "refuses to retire the app's live home (would orphan it)" do
    res = run_tool(from_server_name: "new-box") # the app's own home
    refute res.success?
    assert_match(/orphan|move it/i, res.error)
    assert_equal 0, Decommission.count, "no record on a refused retire"
  end

  test "an unknown app is a clean failure" do
    res = run_tool(app_name: "Nope")
    refute res.success?
    assert_match(/not found/i, res.error)
  end
end
