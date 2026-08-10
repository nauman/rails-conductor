require "test_helper"

# Residue detection existed end-to-end — detector, hourly sweep job, stored
# rollup columns, and a DeployPreflight reader — but `situation` never mentioned
# it. So the resume point an agent actually reads said "nothing wrong" while a
# stale route sat in the rollup, and both residues on this fleet were ultimately
# found by a human sweeping by hand.
class FleetSituationResidueTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "res@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Residue Co")
    @server = Server.create!(name: "res-box", status: "online", organization: @org)
    @app = @org.apps.create!(name: "Residual", slug: "residual", server: @server,
                             deploy_method: "kamal", domain: "residual.test")
  end

  def situation = FleetSituation.new(server_scope: Server.where(id: @server.id)).snapshot[:needs_attention]

  def record_residue(findings, checked_at: Time.current)
    @app.update_columns(residue_findings: findings, residue_checked_at: checked_at)
  end

  test "a stored residue finding reaches the resume point" do
    record_residue([ { "kind" => "orphan_edge_route",
                       "detail" => "residual.test is routed to deadbeef:3000, but no such container is running",
                       "remedy" => "republish the route, or remove it if the app moved boxes" } ])

    row = situation.find { |r| r[:kind] == "residue" }
    assert row, "expected a residue row: #{situation.map { |r| r[:kind] }.inspect}"
    assert_equal "Residual", row[:app]
    assert_match(/orphan_edge_route/, row[:detail])
    assert_match(/republish/, row[:remedy].to_s)
  end

  test "a clean rollup produces no residue row" do
    record_residue([])
    assert_nil situation.find { |r| r[:kind] == "residue" }
  end

  test "a stale rollup is reported as stale rather than presented as current" do
    record_residue([ { "kind" => "duplicate_container", "detail" => "two containers serving", "remedy" => "remove one" } ],
                   checked_at: (ResidueCheckJob::STALE_AFTER + 1.hour).ago)

    row = situation.find { |r| r[:kind] == "residue" }
    assert row
    assert row[:stale], "an unrefreshed result must not read as current"
  end

  test "several findings are summarised without dropping any" do
    record_residue([
      { "kind" => "orphan_edge_route", "detail" => "a", "remedy" => "x" },
      { "kind" => "stale_revision_container", "detail" => "b", "remedy" => "y" }
    ])

    row = situation.find { |r| r[:kind] == "residue" }
    assert_equal 2, row[:count]
    assert_match(/orphan_edge_route/, row[:detail])
    assert_match(/stale_revision_container/, row[:detail])
  end
end
