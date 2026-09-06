require "test_helper"

# The venue has to DECIDE something. BuildPlacement ranked venues and was consulted
# only by preflight, so it described a choice nothing acted on; the real venue came
# from whether DOCKER_HOST got set, which followed from whether a server happened to
# have a key stored.
class BuildVenueRoutingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "bvr@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @control = @org.servers.create!(name: "control", status: "online", ip_address: "10.0.0.1")
    @target = @org.servers.create!(name: "target", status: "online", ip_address: "10.0.0.2")
    @org.apps.create!(name: "conductor", slug: "conductor", server: @control, deploy_method: "kamal",
                      port: 3000, repository_url: "https://github.com/x/c.git", self_managed: true)
    @app = @org.apps.create!(name: "appone", slug: "appone", server: @target, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
  end

  def env_for(app)
    d = KamalDeployer.new(app, app.deployments.create!(user: @user, status: "deploying"))
    d.instance_variable_set(:@ssh_home, "/tmp/fake-ssh-home/.ssh")
    d.send(:deploy_env)
  end

  # The control venue means: do not hand the build to the target's docker daemon.
  test "the control venue does not point the build at the target" do
    @app.update!(build_venue: "control")

    env = env_for(@app)

    assert_nil env["DOCKER_HOST"], "a control-machine build must not use the target's daemon"
  end

  test "the target venue points the build at the target" do
    @app.update!(build_venue: "target")

    env = env_for(@app)

    assert_includes env["DOCKER_HOST"].to_s, @target.ip_address
  end

  # The deploy STOPS. Relocating the build would make the choice decorative, and
  # relocation is exactly how an app ends up compiling on the machine it serves from.
  # The TARGET venue is the one that can genuinely be unusable — it needs a reachable
  # host with a key. (`control` cannot fail: it means "build here", and Conductor is
  # here.) The check runs before any clone, so a policy problem is not buried under
  # whatever else broke first.
  test "a deploy stops when the chosen venue cannot take the build" do
    @app.update!(build_venue: "target")
    @target.update!(status: "offline")
    deployment = @app.deployments.create!(user: @user, status: "deploying")

    KamalDeployer.new(@app, deployment).deploy!

    assert_equal "failed", deployment.reload.status
    assert_match(/build venue/i, deployment.log.to_s)
    assert_match(/offline/i, deployment.log.to_s)
  end

  # An app that predates the choice must keep doing exactly what it did, or this
  # change relocates every live app's build on a deploy nobody is watching.
  test "an app with no chosen venue keeps building where it did" do
    @app.update_columns(build_venue: nil)

    env = env_for(@app)

    assert_includes env["DOCKER_HOST"].to_s, @target.ip_address
  end
end
