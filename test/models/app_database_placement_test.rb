require "test_helper"

# Slice 1 of app-transfer (spec 26): the two per-app DB axes —
# database_mode (isolation) × database_placement (locality). Decision A locked
# the defaults to dedicated + colocated.
class AppDatabasePlacementTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "db-axes@example.com")
    @org = Organization.create_for(user, name: "Acme")
  end

  def build_app(**attrs)
    @org.apps.create!(name: "Appone", slug: "appone", deploy_method: "docker",
                      repository_url: "https://github.com/x/y.git", **attrs)
  end

  test "new apps default to dedicated + colocated (Decision A)" do
    app = build_app
    assert_equal "dedicated", app.database_mode
    assert_equal "colocated", app.database_placement
    assert app.dedicated_db?
    assert app.colocated_db?
    refute app.shared_db?
    refute app.dedicated_db_host?
  end

  test "accepts the shared cluster on a dedicated DB host cell" do
    app = build_app(database_mode: "shared", database_placement: "dedicated_host")
    assert app.shared_db?
    assert app.dedicated_db_host?
    assert_equal "shared·dedicated_host", app.database_cell
  end

  test "rejects an unknown mode or placement" do
    app = build_app
    app.database_mode = "sharded"
    refute app.valid?
    assert_includes app.errors[:database_mode], "is not included in the list"

    app.database_mode = "dedicated"
    app.database_placement = "the_cloud"
    refute app.valid?
    assert_includes app.errors[:database_placement], "is not included in the list"
  end

  test "database_cell names the current cell for the transfer planner" do
    assert_equal "dedicated·colocated", build_app.database_cell
  end

  test "dedicated_database is server-scoped — source and target resolve independently" do
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    src = @org.servers.create!(name: "a", status: "online", ip_address: "10.0.0.1", ssh_key: key, ssh_user: "deploy")
    dst = @org.servers.create!(name: "b", status: "online", ip_address: "10.0.0.2", ssh_key: key, ssh_user: "deploy")
    app = build_app(server: src) # dedicated + colocated by default

    # Same container name (`appone-db`) on BOTH boxes — the transfer window.
    [ src, dst ].each do |server|
      cluster = @org.database_clusters.create!(server: server, name: app.dedicated_db_container_name,
                                               container_name: app.dedicated_db_container_name,
                                               admin_username: "conductor", admin_password: "x", port: 5432)
      cluster.databases.create!(organization: @org, app: app, name: "appone",
                                username: "u_#{server.name}", password: "pw", status: "active")
    end

    assert_equal "u_a", app.dedicated_database(server: src).username
    assert_equal "u_b", app.dedicated_database(server: dst).username
    # The deploy env injects the DB on the box being deployed to.
    assert_includes app.deploy_env_pairs(server: dst).to_h["DATABASE_URL"], "u_b:pw@appone-db"
  end
end
