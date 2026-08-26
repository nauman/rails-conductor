require "test_helper"

# ADR 0007: a finding must cite the ritual that resolves it. A one-line remedy
# answers "what do I type" — it cannot carry ordering, or what a check rules out.
class FleetSituationRecipesTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "recipes@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.9")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "kamal",
                             port: 3000, domain: "shop.test",
                             repository_url: "https://github.com/x/y.git")
  end

  # Through the public snapshot, so this exercises what MCP actually returns
  # rather than a private method's shape.
  def finding(kind)
    FleetSituation.new(server_scope: Server.where(id: @server.id))
                  .snapshot[:needs_attention].find { |i| i[:kind] == kind }
  end

  # The finding that started this: the ritual existed only in a session transcript.
  test "a live orphan cites the diagnostic ritual, not just a remedy line" do
    @app.update_columns(
      residue_findings: [ { "kind" => "live_candidate", "detail" => "app-1-r1-old is a RUNNING candidate",
                            "remedy" => "docker stop app-1-r1-old" } ],
      residue_checked_at: Time.current
    )

    item = finding("residue")
    assert item, "expected a residue finding"
    assert_equal "diagnose-live-orphan", item[:recipe_id]
  end

  test "a deploy hold cites its ritual" do
    @app.update!(deploy_hold: true, deploy_hold_reason: "held")

    assert_equal "diagnose-deploy-hold", finding("deploy_hold")[:recipe_id]
  end

  test "building on a serving box cites its ritual" do
    @app.update_columns(build_host: "ssh://deploy@10.0.0.9")

    assert_equal "diagnose-build-placement", finding("build_on_serving_host")[:recipe_id]
  end

  # A residue finding with no matching ritual must not borrow another one — a
  # wrong ritual is worse than none, because it is followed.
  test "an unmapped finding carries no recipe rather than a wrong one" do
    @app.update_columns(
      residue_findings: [ { "kind" => "unknown", "detail" => "could not inspect", "remedy" => "fix access" } ],
      residue_checked_at: Time.current
    )

    assert_nil finding("residue")[:recipe_id]
  end

  # Codex caught this: `release_drift` collapses four release states, and the
  # drift ritual describes only two of them. `unknown` means the detector could
  # not look at all — handing that reader a mutable-tag procedure is the wrong
  # ritual, and a wrong ritual gets followed.
  test "release drift resolves from the sub-state, not the umbrella kind" do
    { "drift" => "diagnose-release-drift", "unrecorded" => "diagnose-release-drift",
      "unknown" => nil, "mixed_release" => nil }.each do |status, expected|
      @app.update_columns(release_state: { "status" => status, "detail" => "d", "remedy" => "r" },
                          release_checked_at: Time.current)

      actual = finding("release_drift")[:recipe_id]
      if expected.nil?
        assert_nil actual, "release state #{status} must resolve to no ritual"
      else
        assert_equal expected, actual, "release state #{status} must resolve to #{expected}"
      end
    end
  end

  # A deploy blocks on holds, failed seeds, a missing port, an at-risk audit. Only
  # one of those is a hold.
  test "a deploy blocked by something other than a hold cites no ritual" do
    @app.deployments.create!(status: "blocked", user: @org.users.first,
                             preflight_snapshot: [ { "key" => "seeds", "label" => "Seeds", "detail" => "failed" } ].to_json)

    assert_nil finding("blocked_deploy")[:recipe_id]
  end

  test "a deploy blocked by a hold does cite the hold ritual" do
    @app.deployments.create!(status: "blocked", user: @org.users.first,
                             preflight_snapshot: [ { "key" => "threads", "label" => "Threads / hold", "detail" => "held" } ].to_json)

    assert_equal "diagnose-deploy-hold", finding("blocked_deploy")[:recipe_id]
  end

  # detail, remedy and recipe must describe the SAME finding. The detector runs
  # stale-revision before live-candidate, so this ordering is the realistic one.
  test "an aggregated residue row leads with the finding whose ritual it cites" do
    @app.update_columns(
      residue_findings: [
        { "kind" => "stale_revision_container", "detail" => "old-container from revision 2", "remedy" => "docker rm old" },
        { "kind" => "live_candidate", "detail" => "app-1-r1-old is a RUNNING candidate", "remedy" => "docker stop app-1-r1-old" }
      ],
      residue_checked_at: Time.current
    )

    item = finding("residue")
    assert_equal "diagnose-live-orphan", item[:recipe_id]
    assert_includes item[:detail], "RUNNING candidate", "detail must describe the finding whose ritual is cited"
    assert_includes item[:remedy], "docker stop"
  end

  # Every recipe a finding points at must actually exist, or MCP hands an agent a
  # dangling id and the pointer is worse than the prose it replaced.
  test "every finding recipe id resolves to a seeded recipe" do
    ids = FleetRecipes.recipe_ids
    FleetRecipes::FINDING_RECIPES.each_value do |recipe_id|
      assert_includes ids, recipe_id, "#{recipe_id} is referenced by a finding but never seeded"
    end
  end
end
