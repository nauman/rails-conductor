require "test_helper"

class AppTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    user = User.create!(email: "app-test@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9",
                                   ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git", branch: "main")
    @user = user
  end

  test "start_deployment! creates a deployment and enqueues the job when none is in flight" do
    assert_enqueued_with(job: DeployAppJob) do
      deployment, already_running = @app.start_deployment!(user: @user)
      assert_not already_running
      assert deployment.persisted?
      assert deployment.in_progress?
    end
  end

  test "start_deployment! returns the existing deployment as already_running, no second job" do
    existing, = @app.start_deployment!(user: @user)

    assert_no_enqueued_jobs do
      deployment, already_running = @app.start_deployment!(user: @user)
      assert already_running
      assert_equal existing.id, deployment.id
    end
    assert_equal 1, @app.deployments.in_progress.count, "must not create a second in-flight deployment"
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

  test "the index is scoped per app — two different apps can each deploy" do
    other = @org.apps.create!(name: "Wise", slug: "wise", server: @server, deploy_method: "kamal",
                              repository_url: "https://github.com/pavelabs/wise.git", branch: "main")
    @app.deployments.create!(user: @user)

    assert_nothing_raised do
      other.deployments.create!(user: @user)
    end
  end
end
