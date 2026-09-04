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
    assert_equal @app.dedicated_db_container_name, cluster.container_name

    # The container client was asked to run the right container, on the SAME
    # network the app runs on (Kamal's "kamal" net) so <app>-db:5432 resolves.
    assert_equal @app.dedicated_db_container_name, cc.spec[:container_name]
    assert_equal @app.dedicated_db_volume, cc.spec[:volume]
    assert_equal "kamal", cc.spec[:network]
    assert cc.spec[:admin_username].present?
    assert cc.spec[:admin_password].present?

    assert_equal "active", db.status
    assert_equal "appone_production", db.name
    assert_equal "appone", db.username
    assert_equal @app, db.app
    assert_match %r{@#{@app.dedicated_db_container_name}:5432/appone_production\z}, db.database_url
  end

  test "refuses a shared-mode app" do
    @app.update!(database_mode: "shared")
    assert_raises(DedicatedDbProvisioner::NotDedicated) { provision }
  end

  test "refuses dedicated_host placement — not reachable across boxes yet" do
    @app.update!(database_placement: "dedicated_host")
    assert_raises(DedicatedDbProvisioner::Unreachable) { provision }
  end

  # This asserted that a `docker` app was refused, and had been failing locally
  # since `fe5da70` (spec 26, "fix DB reachability") deliberately gave docker apps
  # a deploy_network so their containers can resolve conductor-postgres by name.
  # The guard is `unless @app.deploy_network`, which is now nil only for `native`,
  # so docker apps legitimately pass and native ones are the refused case.
  # Nothing caught the drift because .githooks/pre-push was never wired
  # (core.hooksPath unset) — fixed alongside this.
  # NOTE for whoever owns spec 26: the provisioner's comment still says "non-Kamal
  # apps (their network wiring isn't built yet)", which now contradicts App#deploy_network.
  # One of the two should be corrected; I have only realigned the test with shipped behaviour.
  test "refuses a native app — a host process shares no docker network with its DB" do
    @app.update!(deploy_method: "native")
    assert_raises(DedicatedDbProvisioner::Unreachable) { provision }
  end

  test "allows a docker app — spec 26 puts it on the shared network" do
    @app.update!(deploy_method: "docker")
    assert_nothing_raised { provision }
  end

  test "is idempotent — reuses the existing cluster + database" do
    cc = FakeContainerClient.new
    first = provision(cc)
    second = provision(cc)

    assert_equal first.id, second.id
    assert_equal 1, @org.database_clusters.count
    assert_equal 1, Database.where(app: @app).count
  end

  test "retry reuses the persisted cluster password (no auth-breaking rotation)" do
    cc = FakeContainerClient.new
    db = provision(cc)
    # The container is always ensured with the cluster's PERSISTED password, so a
    # retry after a partial failure can't leave the row and container out of sync.
    assert_equal db.database_cluster.admin_password, cc.spec[:admin_password]
  end

  test "reconciles a prior failed database instead of duplicating it" do
    cc = FakeContainerClient.new
    provision(cc)
    # Simulate a prior failed SQL provision leaving an error record.
    Database.where(app: @app).update_all(status: "error")

    provision(cc)

    assert_equal 1, Database.where(app: @app).count, "no duplicate Database rows"
    assert_equal "active", Database.find_by(app: @app).status
  end
end
