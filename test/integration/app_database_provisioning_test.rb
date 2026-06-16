require "test_helper"

class AppDatabaseProvisioningTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "owner@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @server = @org.servers.create!(name: "s1", status: "offline")
    @cluster = @org.database_clusters.create!(
      server: @server, name: "shared", container_name: "conductor-postgres",
      admin_username: "conductor", admin_password: "adminpw"
    )
    @target_app = @org.apps.create!(name: "Kuickr", server: @server, status: "stopped", deploy_method: "docker")
    sign_in_as(@user)
  end

  test "provisioning a database for an app links it with a sane name" do
    fake = Object.new
    def fake.create_database(**) = { "action" => "created" }

    assert_difference -> { @target_app.databases.count }, 1 do
      PostgresClusterClient.stub(:new, fake) do
        post provision_database_app_path(@target_app)
      end
    end

    db = @target_app.databases.last
    assert_equal "kuickr_production", db.name
    assert_equal "kuickr", db.username
    assert_equal @target_app, db.app
    assert_equal @cluster, db.database_cluster
  end

  test "provisioning without a cluster is a friendly error" do
    @cluster.destroy
    assert_no_difference -> { Database.count } do
      post provision_database_app_path(@target_app)
    end
    assert_redirected_to @target_app
  end
end
