require "test_helper"

class RollbackAppJobTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "rb@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "s", status: "online", ip_address: "10.0.0.1", ssh_key: key)
  end

  def rollback_deployment_for(method)
    app = @org.apps.create!(name: "a-#{method}", slug: "a-#{method}", server: @server,
                            deploy_method: method, repository_url: "https://example.com/r.git")
    app.deployments.create!(kind: "rollback")
  end

  test "kamal apps roll back via KamalDeployer#rollback! with the target version" do
    deployment = rollback_deployment_for("kamal")
    got = nil
    fake = Object.new
    fake.define_singleton_method(:rollback!) { |version| got = version }
    KamalDeployer.stub(:new, ->(*) { fake }) do
      RollbackAppJob.new.perform(deployment.id, "v-abc123")
    end
    assert_equal "v-abc123", got
  end

  # Docker rollback exists now (ADR 0003 — releases are SHA-tagged and retained),
  # so only native still lacks one.
  test "docker apps route to DockerRollback, not the Kamal deployer" do
    deployment = rollback_deployment_for("docker")
    got = nil
    fake = Object.new
    fake.define_singleton_method(:rollback!) { |version| got = version }

    KamalDeployer.stub(:new, ->(*) { flunk "docker must not use the Kamal deployer" }) do
      DockerRollback.stub(:new, ->(*, **) { fake }) do
        RollbackAppJob.new.perform(deployment.id, "v-abc123")
      end
    end
    assert_equal "v-abc123", got
  end

  test "native apps fail loud without building a deployer" do
    deployment = rollback_deployment_for("native")
    KamalDeployer.stub(:new, ->(*) { flunk "should not construct a deployer for a native app" }) do
      RollbackAppJob.new.perform(deployment.id, "v-abc123")
    end
    assert_equal "failed", deployment.reload.status
    assert_includes deployment.log.to_s, "not supported for native"
  end
end
