require "test_helper"

# The canon is a LEXICON, not a procedure. Rituals live in jazari — recipes,
# checklists, runs — and this names the shapes those rituals apply to, then points
# at one by id. It carries no steps on purpose: a vocabulary that starts holding
# procedures becomes a second task system, and jazari already is the first.
#
# It exists because an app's shape was previously only inferable from prose. Today
# `deploy_method` conflates the artifact contract with the deploy DRIVER, which is
# why InventList cannot record the truth (`docker`) without flipping a residue
# heuristic on and manufacturing false findings. Separate axes fix that.
class FleetCanonTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "canon@example.com")
    @org = Organization.create_for(user, name: "Canon Co")
    @caddy = @org.servers.create!(name: "caddy-box", status: "online", edge_type: "caddy")
    @proxy = @org.servers.create!(name: "proxy-box", status: "online", edge_type: "kamal_proxy")
  end

  def app(**attrs)
    @org.apps.create!({ name: "A#{SecureRandom.hex(3)}", slug: "a#{SecureRandom.hex(3)}",
                        deploy_method: "kamal" }.merge(attrs))
  end

  test "the lexicon is closed and names every axis" do
    assert_equal %i[artifact driver edge], FleetCanon::AXES
    assert_includes FleetCanon::DRIVERS, "external"
    assert_includes FleetCanon::DRIVERS, "conductor"
  end

  test "a kamal app on a kamal-proxy box is the zero-downtime shape" do
    shape = FleetCanon.shape_for(app(server: @proxy, port: nil))

    assert_equal "kamal", shape[:artifact]
    assert_equal "kamal_proxy", shape[:edge]
    assert_equal "conductor", shape[:driver]
    assert_equal "kamal-proxy-app", shape[:recipe_id]
  end

  test "a kamal app on a caddy box with a published port is the Caddy-mode shape" do
    shape = FleetCanon.shape_for(app(server: @caddy, port: 9080))

    assert_equal "caddy", shape[:edge]
    assert_equal "caddy-mode-app", shape[:recipe_id],
      "proxy-off plus a fixed port is its own ritual — the port must be freed before boot"
  end

  # The InventList case. A held app whose notes say it deploys by its own script is
  # externally driven; that is a different fact from which artifact it builds.
  test "an app held with an external deploy path is driven externally, not by Conductor" do
    subject = app(server: @caddy, port: 3000, deploy_hold: true,
                  deploy_hold_reason: "deploys use repo bin/deploy-ssdnode — do NOT kamal deploy")
    shape = FleetCanon.shape_for(subject)

    assert_equal "external", shape[:driver]
    assert_equal "external-driver-app", shape[:recipe_id]
    assert_equal "kamal", shape[:artifact], "the artifact contract is unchanged by who rolls it"
  end

  test "a hold that is not about an external path does not change the driver" do
    subject = app(server: @proxy, deploy_hold: true, deploy_hold_reason: "waiting on a thread reply")

    assert_equal "conductor", FleetCanon.shape_for(subject)[:driver]
  end

  test "a native app is its own shape regardless of the box edge" do
    assert_equal "native-app", FleetCanon.shape_for(app(server: @caddy, deploy_method: "native"))[:recipe_id]
  end

  # Composition, not duplication: the canon hands jazari a recipe id and a subject;
  # jazari owns the checklist, the run and the revision guard.
  test "it builds a jazari RecordTarget for a subject without carrying any steps" do
    subject = app(server: @caddy, port: 9080)
    target = FleetCanon.target_for(subject)

    assert_equal subject, target.runbookable
    assert_equal "caddy-mode-app", target.recipe_id
    assert_match(/app-#{subject.id}/, target.public_reference)
  end

  # Was a tautology: Hash#keys is unique by definition, so the old assertion could
  # never fail while claiming to prove a pointer cannot dangle (caught in review of
  # PR #34). The dangling-pointer property is genuinely tested in
  # FleetRecipesTest#"every recipe the canon can point at has content behind it";
  # what belongs HERE is that the map itself is sane.
  test "no two shapes point at the same recipe, and every id is a usable slug" do
    ids = FleetCanon::RECIPES.values

    assert_equal ids.uniq, ids,
      "two shapes pointing at one recipe means one of them has no ritual of its own: #{ids.inspect}"
    ids.each { |id| assert_match(/\A[a-z0-9-]+\z/, id, "#{id} is not a usable recipe id") }
  end
end
