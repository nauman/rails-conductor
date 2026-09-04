require "test_helper"

# The path an agent takes to give a new app a database. The convention was written
# into the tool's schema but never into its behaviour: omitting `name` passed nil.
class ProvisionDatabaseConventionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "pdc@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.52")
    @cluster = @org.database_clusters.create!(name: "shared", container_name: "shared",
                                              server: @server, admin_username: "conductor",
                                              admin_password: "x", port: 5432)
    @app = @org.apps.create!(name: "hush", slug: "hush", server: @server, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
  end

  class FakeSql
    def create_database(*) = true
    def create_role(*) = true
  end

  def call(input)
    PostgresClusterClient.stub(:new, FakeSql.new) do
      ProvisionDatabaseTool.new(user: @user).call(input.merge("cluster_id" => @cluster.id))
    end
  end

  test "omitting name follows the convention from app_id" do
    result = call("app_id" => @app.id)

    assert result.success?, result.error
    assert_equal @app.database_name, result.value[:name]
    assert_equal @app.database_username, result.value[:username]
  end

  test "an explicit name creates under that name, and the role follows it" do
    result = call("app_id" => @app.id, "name" => "legacy_db")

    assert result.success?, result.error
    assert_equal "legacy_db", result.value[:name]
    assert_equal "legacy_db", result.value[:username], "the role follows the database, not the app"
  end

  # Without an app there is no convention to fall back on, and a nil name reached
  # CREATE DATABASE. Say so instead.
  test "neither a name nor an app is refused, not attempted" do
    result = call({})

    assert_not result.success?
    assert_match(/app_id/, result.error)
    assert_no_match(/blank/i, result.error, "a validation error is not an explanation")
  end
end
