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

  # The host is the cluster's ASSIGNED alias, not its container_name (ADR 0011).
  # This cluster is SHARED — its container_name was typed by an operator at
  # register_cluster and is editable — so it is exactly the case where a rename used
  # to silently break the next deploy of every app on it.
  test "database_url uses the shared cluster's assigned alias once it is attached" do
    @cluster.alias_attached!(network: "kamal", client: FakeDocker.new([ @cluster.resource_key ]))
    db = @org.databases.create!(database_cluster: @cluster, name: "appone_production",
                                username: "appone", password: "secret", status: "active")

    assert_equal "postgres://appone:secret@cluster-#{@cluster.id}:5432/appone_production", db.database_url
  end

  # Before the alias exists on the container, the typed name is the only thing Docker
  # DNS answers — switching first would break every app on this cluster at once.
  test "database_url keeps the typed name until the alias is attached" do
    db = @org.databases.create!(database_cluster: @cluster, name: "appone_production",
                                username: "appone", password: "secret", status: "active")

    assert_equal "postgres://appone:secret@conductor-postgres:5432/appone_production", db.database_url
  end

  test "App#database_base_name sanitizes the app name to a valid identifier" do
    app = @org.apps.create!(name: "App.two", server: @server, status: "stopped")
    assert_equal "app_two", app.database_base_name
  end

  class FakeDocker
    attr_reader :asked
    def initialize(aliases) = (@aliases = aliases)
    def network_aliases(container_name:, network:)
      @asked = [ container_name, network ]
      @aliases
    end
  end
end
