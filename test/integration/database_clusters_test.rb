require "test_helper"

class DatabaseClustersTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "owner@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @server = @org.servers.create!(name: "s1", status: "offline")
    sign_in_as(@user)
  end

  test "register a cluster, then provision a database on it" do
    assert_difference -> { @org.database_clusters.count }, 1 do
      post database_clusters_path, params: { database_cluster: {
        server_id: @server.id, name: "shared", container_name: "conductor-postgres",
        admin_username: "conductor", admin_password: "adminpw"
      } }
    end
    cluster = @org.database_clusters.last

    # Stub the SSH client so the request doesn't hit a real server.
    fake = Object.new
    def fake.create_database(**) = { "action" => "created" }

    assert_difference -> { @org.databases.count }, 1 do
      PostgresClusterClient.stub(:new, fake) do
        post database_cluster_databases_path(cluster), params: { database: { name: "acme_production" } }
      end
    end
    assert_equal "active", @org.databases.last.status
  end

  test "cannot view another org's cluster" do
    other = Organization.create!(name: "Other")
    theirs = other.database_clusters.create!(
      server: @server, name: "x", container_name: "c", admin_username: "u", admin_password: "p"
    )
    get database_cluster_path(theirs)
    assert_response :not_found
  end

  test "drop a database removes the record" do
    cluster = @org.database_clusters.create!(
      server: @server, name: "shared", container_name: "conductor-postgres",
      admin_username: "conductor", admin_password: "adminpw"
    )
    db = @org.databases.create!(database_cluster: cluster, name: "doomed", username: "doomed", password: "x", status: "active")

    fake = Object.new
    def fake.drop_database(**) = { "action" => "dropped" }

    assert_difference -> { @org.databases.count }, -1 do
      PostgresClusterClient.stub(:new, fake) do
        delete database_path(db)
      end
    end
  end
end
