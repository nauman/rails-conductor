require "test_helper"

class DatabaseClusterTest < ActiveSupport::TestCase
  class StubClient
    attr_reader :created
    def create_database(**kwargs)
      @created = kwargs
      { "action" => "created" }
    end
  end

  setup do
    user = User.create!(email: "o@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "s1", status: "offline")
    @cluster = @org.database_clusters.create!(
      server: @server, name: "shared", container_name: "conductor-postgres",
      admin_username: "conductor", admin_password: "adminpw"
    )
  end

  test "provision_database! creates an active Database scoped to the org and runs the client" do
    stub = StubClient.new

    db = @cluster.provision_database!(name: "acme_production", client: stub)

    assert_equal "active", db.status
    assert_equal @cluster, db.database_cluster
    assert_equal @org, db.organization
    assert db.password.present?, "a password should be generated"
    assert_includes @org.databases, db
    assert_equal "acme_production", stub.created[:name]
  end

  test "a failed provision marks the Database errored" do
    failing = Class.new do
      def create_database(**); raise PostgresClusterClient::Error, "boom"; end
    end.new

    assert_raises(PostgresClusterClient::Error) do
      @cluster.provision_database!(name: "acme_production", client: failing)
    end
    assert_equal "error", @cluster.databases.last.status
  end
end
