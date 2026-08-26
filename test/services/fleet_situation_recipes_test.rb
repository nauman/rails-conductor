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

  # Every recipe a finding points at must actually exist, or MCP hands an agent a
  # dangling id and the pointer is worse than the prose it replaced.
  test "every finding recipe id resolves to a seeded recipe" do
    ids = FleetRecipes.recipe_ids
    FleetRecipes::FINDING_RECIPES.each_value do |recipe_id|
      assert_includes ids, recipe_id, "#{recipe_id} is referenced by a finding but never seeded"
    end
  end
end
