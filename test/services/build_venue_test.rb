require "test_helper"

# WHERE AN IMAGE IS BUILT WAS NEVER CHOSEN. DOCKER_HOST is pointed at the deploy
# target only when that server happens to have a stored SSH key, so an app built on
# the target or on the control machine according to something nobody was deciding —
# and BuildPlacement's "control machine" rung described a venue nothing routed to.
class BuildVenueTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "bv@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @control = @org.servers.create!(name: "control", status: "online", ip_address: "10.0.0.1")
    @target = @org.servers.create!(name: "target", status: "online", ip_address: "10.0.0.2")
    # Conductor's own app identifies the control machine — it is the box Conductor
    # runs on, which is the only thing that makes "build here" meaningful.
    @org.apps.create!(name: "conductor", slug: "conductor", server: @control, deploy_method: "kamal",
                      port: 3000, repository_url: "https://github.com/x/c.git", self_managed: true)
    @app = @org.apps.create!(name: "appone", slug: "appone", server: @target, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
  end

  test "a new app chooses the control machine rather than inheriting a venue" do
    assert_equal "control", @app.build_venue
  end

  # Existing apps predate the choice. Flipping their venue silently would change
  # where every live app builds, on a deploy nobody is watching.
  test "an app that predates the choice keeps its current behaviour" do
    @app.update_columns(build_venue: nil)

    assert_nil @app.reload.build_venue
    assert @app.build_venue_inherited?, "an unchosen venue must be visible as unchosen"
  end

  test "the control machine is the box Conductor itself runs on" do
    assert_equal @control, @app.control_machine
  end

  # The control venue is ALWAYS available — it means "do not hand the build to a
  # remote daemon", and Conductor is running wherever it is running. An earlier
  # version required a registered self-managed app to name the box and refused the
  # deploy without one, which is every fresh install: a check that fails for anyone
  # who has not done unrelated bookkeeping is an outage, not a check.
  test "the control venue needs no bookkeeping to be usable" do
    @app.update!(build_venue: "control")

    assert_nil @app.build_venue_unavailable_reason
  end

  test "the control venue is usable even where Conductor is not registered as an app" do
    App.where(self_managed: true).destroy_all
    @app.update!(build_venue: "control")

    assert_nil @app.control_machine, "nothing names the box, and that is fine"
    assert_nil @app.build_venue_unavailable_reason, "naming it is reporting, not permission"
  end

  # NO SUBSTITUTION, where a venue genuinely can fail: the target needs a key.
  test "an unusable target fails the deploy instead of relocating it" do
    @app.update!(build_venue: "target")
    @target.update!(status: "offline")

    assert_match(/offline/i, @app.build_venue_unavailable_reason)
  end

  # The target venue is still a legitimate choice — it is what most apps do today —
  # and it needs the target's SSH key, which is what made it accidental before.
  test "the target venue requires a key Conductor can build with" do
    @app.update!(build_venue: "target")

    assert_match(/ssh key/i, @app.build_venue_unavailable_reason.to_s)
  end
end
