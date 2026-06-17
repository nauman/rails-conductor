require "test_helper"

class AppManagementToolsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "mgmt@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9", ssh_key: key)
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", server: @server, deploy_method: "docker", status: "stopped")
  end

  test "update_app sets deploy_method, repository_url and notes" do
    res = UpdateAppTool.new(user: @user).call(
      "app_name" => "Kuickr", "deploy_method" => "kamal",
      "repository_url" => "https://github.com/pavelabs/kuickr.git",
      "notes" => "Fleet box; shared conductor-postgres; SES email."
    )
    assert res.success?, res.error
    assert_equal "kamal", @app.reload.deploy_method
    assert_equal "Fleet box; shared conductor-postgres; SES email.", @app.notes
    assert_equal @org, res.value[:_organization]
  end

  test "update_app rejects an invalid deploy_method" do
    res = UpdateAppTool.new(user: @user).call("app_id" => @app.id, "deploy_method" => "bogus")
    refute res.success?
    assert_includes res.error, "Invalid deploy_method"
  end

  test "sync_app_status runs the kamal sync and reports running" do
    @app.update!(deploy_method: "kamal")
    fake = Object.new
    def fake.sync! = true
    def fake.success? = true
    def fake.error = nil
    # Make the underlying ContainerStatus flip the app to running.
    ContainerStatus.stub(:new, ->(app) { app.update!(status: "running", container_status: "running"); fake }) do
      res = SyncAppStatusTool.new(user: @user).call("app_name" => "Kuickr")
      assert res.success?
      assert_equal "running", res.value[:status]
      assert_equal "kamal", res.value[:deploy_method]
    end
  end

  test "sync_app_status fails cleanly when the app can't be synced (no ssh)" do
    nossh = @org.apps.create!(name: "NoSSH", slug: "nossh", deploy_method: "kamal", status: "stopped")
    res = SyncAppStatusTool.new(user: @user).call("app_id" => nossh.id)
    refute res.success?
    assert_includes res.error, "can't be status-synced"
  end
end
