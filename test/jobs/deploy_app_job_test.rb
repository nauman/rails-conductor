require "test_helper"

class DeployAppJobTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "j@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "s", status: "online", ip_address: "10.0.0.1", ssh_key: key)
  end

  def deployment_for(method)
    app = @org.apps.create!(name: "a-#{method}", slug: "a-#{method}", server: @server,
                            deploy_method: method, repository_url: "https://example.com/r.git")
    app.deployments.create!
  end

  test "dispatches Conductor-driven Kamal artifacts through AppDeployer" do
    deployment = deployment_for("kamal")
    called = nil
    app_deployer = ->(*) { obj = Object.new; obj.define_singleton_method(:deploy!) { called = :conductor }; obj }

    KamalDeployer.stub(:new, ->(*) { flunk "Kamal is an ops utility, not Conductor's deploy driver" }) do
      AppDeployer.stub(:new, app_deployer) do
        DeployAppJob.new.perform(deployment.id)
      end
    end

    assert_equal :conductor, called
  end

  test "dispatches native apps to NativeDeployer" do
    deployment = deployment_for("native")
    called = nil
    NativeDeployer.stub(:new, ->(*) { obj = Object.new; obj.define_singleton_method(:deploy!) { called = :native }; obj }) do
      DeployAppJob.new.perform(deployment.id)
    end
    assert_equal :native, called
  end

  test "dispatches docker apps to AppDeployer" do
    deployment = deployment_for("docker")
    called = nil
    AppDeployer.stub(:new, ->(*) { obj = Object.new; obj.define_singleton_method(:deploy!) { called = :docker }; obj }) do
      DeployAppJob.new.perform(deployment.id)
    end
    assert_equal :docker, called
  end

  # Fix for the self-deploy loop + false "deploy failed" emails: when Conductor
  # deploys itself, kamal SIGTERMs this job mid-roll and SolidQueue re-runs it. A
  # re-run of a self-managed deploy that's already "deploying" must NOT invoke the
  # deployer again (that re-run raced the lock, failed, and emailed) — the reconciler
  # finalizes the row when the new release boots.
  test "self-managed deploy already mid-roll is NOT re-run" do
    app = @org.apps.create!(name: "conductor", slug: "conductor", server: @server,
                            deploy_method: "kamal", repository_url: "https://example.com/r.git",
                            self_managed: true)
    deployment = app.deployments.create!(status: "deploying", commit_sha: "abc123def456")

    called = false
    KamalDeployer.stub(:new, ->(*) { obj = Object.new; obj.define_singleton_method(:deploy!) { called = true }; obj }) do
      DeployAppJob.new.perform(deployment.id)
    end

    refute called, "a mid-roll self-managed deploy must not be re-run"
    assert_equal "deploying", deployment.reload.status
    assert_match(/re-entered/i, deployment.log.to_s)
  end

  test "a fresh self-managed in-product deploy is refused" do
    app = @org.apps.create!(name: "conductor2", slug: "conductor2", server: @server,
                            deploy_method: "kamal", repository_url: "https://example.com/r.git",
                            self_managed: true)
    deployment = app.deployments.create! # status defaults to pending, not "deploying"

    AppDeployer.stub(:new, ->(*) { flunk "self-managed deploy must stop before dispatch" }) do
      KamalDeployer.stub(:new, ->(*) { flunk "self-managed deploy must stop before dispatch" }) do
        DeployAppJob.new.perform(deployment.id)
      end
    end

    assert_equal "failed", deployment.reload.status
    assert_match(/deploy from CI, not in-product/, deployment.failure_reason)
  end

  # The infinite-handoff hole: the reconciler finalizes the row to "succeeded" on
  # the new container's boot; a re-run that saw a terminal row and re-deployed
  # kept the loop alive. A re-run of ANY non-pending self-managed deploy must bail.
  test "a re-run of a terminal (succeeded/failed) self-managed deploy is NOT re-run" do
    app = @org.apps.create!(name: "conductor3", slug: "conductor3", server: @server,
                            deploy_method: "kamal", repository_url: "https://example.com/r.git",
                            self_managed: true)
    %w[succeeded failed cancelled building].each do |state|
      dep = app.deployments.create!(status: state, commit_sha: "sha-#{state}")
      called = false
      KamalDeployer.stub(:new, ->(*) { obj = Object.new; obj.define_singleton_method(:deploy!) { called = true }; obj }) do
        DeployAppJob.new.perform(dep.id)
      end
      refute called, "a re-run of a '#{state}' self-managed deploy must not re-run kamal"
    end
  end
end
