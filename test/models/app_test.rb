require "test_helper"

class AppTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    user = User.create!(email: "app-test@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9",
                                   ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/appone.git", branch: "main")
    @user = user
  end

  test "start_deployment! creates a deployment and enqueues the job when none is in flight" do
    assert_enqueued_with(job: DeployAppJob) do
      deployment, status, = @app.start_deployment!(user: @user)
      assert_equal :started, status
      assert deployment.persisted?
      assert deployment.in_progress?
    end
  end

  test "start_deployment! returns the existing deployment as already_running, no second job" do
    existing, = @app.start_deployment!(user: @user)

    assert_no_enqueued_jobs do
      deployment, status, = @app.start_deployment!(user: @user)
      assert_equal :already_running, status
      assert_equal existing.id, deployment.id
    end
    assert_equal 1, @app.deployments.in_progress.count, "must not create a second in-flight deployment"
  end

  test "start_deployment! blocks (no job) when the preflight fails, unless forced" do
    @app.update!(deploy_hold: true, deploy_hold_reason: "thread owed")
    assert_no_enqueued_jobs do
      deployment, status, preflight = @app.start_deployment!(user: @user)
      assert_equal :blocked, status
      assert_nil deployment
      assert preflight.blocked?
    end

    assert_enqueued_with(job: DeployAppJob) do
      _deployment, status, = @app.start_deployment!(user: @user, force: true)
      assert_equal :started, status
    end
  end

  test "the unique partial index forbids two in-flight deployments per app (DB invariant)" do
    @app.deployments.create!(user: @user) # in_progress (pending)

    assert_raises(ActiveRecord::RecordNotUnique) do
      @app.deployments.create!(user: @user)
    end
  end

  test "a new deployment is allowed once the prior one is no longer in flight" do
    first = @app.deployments.create!(user: @user)
    first.update!(status: "succeeded")

    assert_nothing_raised do
      second = @app.deployments.create!(user: @user)
      assert second.persisted?
    end
  end

  test "log_tail_command for a native app reaches the user journal (XDG_RUNTIME_DIR) and folds stderr" do
    @app.update!(deploy_method: "native")
    cmd = @app.log_tail_command(150)

    assert_includes cmd, "XDG_RUNTIME_DIR=/run/user/$(id -u)", "user journal needs the runtime dir over non-login ssh"
    assert_includes cmd, "journalctl --user -u #{@app.service_name}"
    assert_includes cmd, "-n 150"
    assert_includes cmd, "2>&1", "stderr must be folded in so errors aren't invisible"
  end

  test "log_tail_command for a docker app tails the container" do
    @app.update!(deploy_method: "docker")
    cmd = @app.log_tail_command(50)

    assert_includes cmd, "docker logs --tail 50 #{@app.container_name}"
    assert_includes cmd, "2>&1"
  end

  test "the index is scoped per app — two different apps can each deploy" do
    other = @org.apps.create!(name: "Wise", slug: "wise", server: @server, deploy_method: "kamal",
                              repository_url: "https://github.com/pavelabs/wise.git", branch: "main")
    @app.deployments.create!(user: @user)

    assert_nothing_raised do
      other.deployments.create!(user: @user)
    end
  end

  test "status sync support covers Docker and Kamal only" do
    @app.update!(deploy_method: "kamal")
    assert @app.status_sync_supported?
    assert @app.can_sync_status?

    @app.update!(deploy_method: "docker")
    assert @app.status_sync_supported?
    assert @app.can_sync_status?

    @app.update!(deploy_method: "native")
    assert_not @app.status_sync_supported?
    assert_not @app.can_sync_status?
  end

  test "restart support requires SSH while dashboard restart excludes native" do
    %w[docker kamal].each do |method|
      @app.update!(deploy_method: method)
      assert @app.restart_supported?
      assert @app.dashboard_restart_supported?
    end

    @app.update!(deploy_method: "native")
    assert @app.restart_supported?
    assert_not @app.dashboard_restart_supported?

    @app.update!(server: nil)
    assert_not @app.restart_supported?
    assert_not @app.dashboard_restart_supported?
  end

  test "Kamal container status becomes stale after five minutes" do
    @app.update!(deploy_method: "kamal", last_status_check_at: 6.minutes.ago)
    assert @app.status_stale?
  end
end
