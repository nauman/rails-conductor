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

  test "dispatches kamal apps to KamalDeployer" do
    deployment = deployment_for("kamal")
    called = nil
    KamalDeployer.stub(:new, ->(*) { obj = Object.new; obj.define_singleton_method(:deploy!) { called = :kamal }; obj }) do
      DeployAppJob.new.perform(deployment.id)
    end
    assert_equal :kamal, called
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
end
