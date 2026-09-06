require "test_helper"

# Moving builds onto the control machine concentrates them on a box that also
# serves live apps. Two concurrent builds are two builds' worth of contention on
# the machine your users are talking to, and nothing bounded that.
class BuildContentionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "bc@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    server = @org.servers.create!(name: "target", status: "online", ip_address: "10.0.0.3")
    @app = @org.apps.create!(name: "appone", slug: "appone", server: server, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
    @deployment = @app.deployments.create!(user: @user, status: "deploying")
  end

  def deployer = KamalDeployer.new(@app, @deployment)

  # The lock is only meaningful where builds share a machine. A target-venue build
  # runs on the app's own server, so serialising it here would queue builds that
  # never contend.
  test "a control-venue build is serialised behind a host-wide lock" do
    @app.update!(build_venue: "control")

    cmd = deployer.send(:kamal_build_command).last

    assert_match(/flock/, cmd)
    assert_match(/--nonblock|-n\b/, cmd, "a build must not sit waiting behind another one indefinitely")
  end

  test "a target-venue build is not serialised on this box" do
    @app.update!(build_venue: "target")

    assert_no_match(/flock/, deployer.send(:kamal_build_command).last)
  end

  # The lock file has to outlive any one deploy and be shared by every worker, so
  # a per-app or container-local path would serialise nothing.
  test "the lock is host-wide, not per app" do
    @app.update!(build_venue: "control")

    cmd = deployer.send(:kamal_build_command).last

    assert_no_match(/appone/, cmd[/flock\s+\S+\s+\S+/].to_s, "a per-app lock serialises nothing")
  end

  # And the deploy must SAY so. Reporting contention as a build failure sends an
  # operator to look at their code, which is the same conflation that made an
  # exhausted CI quota read as a broken commit.
  test "a busy builder leaves the incumbent alone and says why" do
    @app.update!(build_venue: "control", port: 4000)
    d = deployer
    d.define_singleton_method(:fixed_port_app?) { true }
    d.instance_variable_set(:@shell, BusyShell.new)

    assert_not d.send(:build_before_fixed_port_stop)
    assert_match(/contention, not a broken commit/i, @deployment.reload.log.to_s)
    assert_match(/incumbent is untouched/i, @deployment.log.to_s)
  end

  class BusyShell
    def run(*, **)
      LocalShell::Result.new(success: false, exit_code: KamalDeployer::LOCK_BUSY_EXIT, output: "")
    end
  end

  # A busy lock is not a build failure and must not read as one: the commit is
  # fine, the machine is occupied.
  test "a busy builder is reported as contention, not as a broken build" do
    @app.update!(build_venue: "control")

    assert_equal :busy, deployer.send(:build_outcome_for, KamalDeployer::LOCK_BUSY_EXIT)
    assert_equal :failed, deployer.send(:build_outcome_for, 1)
    assert_equal :ok, deployer.send(:build_outcome_for, 0)
  end
end
