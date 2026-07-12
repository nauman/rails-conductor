require "test_helper"

class DatabaseUrlTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "o@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "s1", status: "offline")
    @cluster = @org.database_clusters.create!(
      server: @server, name: "shared", container_name: "conductor-postgres",
      admin_username: "conductor", admin_password: "x", port: 5432
    )
  end

  test "database_url builds a postgres URL from cluster + credentials" do
    db = @org.databases.create!(database_cluster: @cluster, name: "appone_production",
                                username: "appone", password: "secret", status: "active")
    assert_equal "postgres://appone:secret@conductor-postgres:5432/appone_production", db.database_url
  end

  test "App#database_base_name sanitizes the app name to a valid identifier" do
    app = @org.apps.create!(name: "App.two", server: @server, status: "stopped")
    assert_equal "app_two", app.database_base_name
  end
end
