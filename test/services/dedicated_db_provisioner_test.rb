require "test_helper"

# App-transfer spec 26, Slice 2: DedicatedDbProvisioner stands up a per-app
# `<app>-db` Postgres container, registers it as a DatabaseCluster, and
# provisions the app's database on it — reachable by container DNS.
class DedicatedDbProvisionerTest < ActiveSupport::TestCase
  # Records the container spec instead of running docker over SSH.
  class FakeContainerClient
    attr_reader :spec, :calls
    def initialize = @calls = 0
    def create!(**spec)
      @spec = spec
      @calls += 1
      { "action" => "created", "container" => spec[:container_name] }
    end
  end

  # Stands in for PostgresClusterClient (the docker-exec SQL layer).
  class FakeSqlClient
    def create_database(name:, username:, password:)
      { "name" => name, "username" => username, "action" => "created" }
    end
  end

  setup do
    user = User.create!(email: "ded-db@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9",
                                   ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git")
  end

  def provision(cc = FakeContainerClient.new, sql = FakeSqlClient.new)
    DedicatedDbProvisioner.new(app: @app, container_client: cc, sql_client: sql).provision!
  end

  test "stands up a dedicated <app>-db cluster + database wired by container DNS" do
    cc = FakeContainerClient.new
    db = provision(cc)

    cluster = db.database_cluster
    assert_equal @server, cluster.server, "dedicated DB is colocated on the app's server by default"
    assert_equal "appone-db", cluster.container_name

    # The container client was asked to run the right container (name/volume/network).
    assert_equal "appone-db", cc.spec[:container_name]
    assert_equal "appone-db-data", cc.spec[:volume]
    assert_equal "appone-net", cc.spec[:network]
    assert cc.spec[:admin_username].present?
    assert cc.spec[:admin_password].present?

    assert_equal "active", db.status
    assert_equal "appone", db.name
    assert_equal @app, db.app
    assert_match %r{@appone-db:5432/appone\z}, db.database_url
  end

  test "refuses a shared-mode app" do
    @app.update!(database_mode: "shared")
    assert_raises(DedicatedDbProvisioner::NotDedicated) { provision }
  end

  test "is idempotent — reuses the existing cluster + database" do
    cc = FakeContainerClient.new
    first = provision(cc)
    second = provision(cc)

    assert_equal first.id, second.id
    assert_equal 1, @org.database_clusters.count
    assert_equal 1, Database.where(app: @app).count
    assert_equal 1, cc.calls, "the container is only created once"
  end
end
