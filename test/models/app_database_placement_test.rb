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
end
