require "test_helper"

# The other half of the audit: a cluster that reports an identity it does not have.
class ClusterIdentityGuardsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "cig@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.51")
  end

  def app_for(slug)
    @org.apps.create!(name: slug, slug: slug, server: @server, deploy_method: "kamal",
                      port: 3000, repository_url: "https://github.com/x/y.git")
  end

  def cluster(container_name)
    @org.database_clusters.create!(name: container_name, container_name: container_name,
                                   server: @server, admin_username: "conductor",
                                   admin_password: "x", port: 5432)
  end

  # A SHARED cluster that happens to be named `<slug>-db` for ONE of its tenants was
  # read as dedicated — because the check asked whichever app came back first.
  test "a cluster hosting several apps is never read as dedicated" do
    one, two = app_for("one"), app_for("two")
    shared = cluster("one-db")
    shared.provision_database!(name: one.database_name, app: one, client: FakeSql.new)
    shared.provision_database!(name: two.database_name, app: two, client: FakeSql.new)

    assert_not shared.assigned_container_name?, "two tenants means an operator typed this name"
  end

  test "a cluster with a single app that claims the name is still dedicated" do
    app = app_for("solo")
    dedicated = cluster(app.dedicated_db_container_name)
    dedicated.provision_database!(name: app.database_name, app: app, client: FakeSql.new)

    assert dedicated.assigned_container_name?
  end

  # THE LIE. Recording an attachment that nothing performed flips connect_host to a
  # hostname that does not resolve — breaking every app on the cluster at its next
  # deploy, which is the exact ADR 0010 failure this work exists to stop.
  test "an alias cannot be recorded as attached without evidence it resolves" do
    shared = cluster("typed-name")

    assert_raises(DatabaseCluster::AliasNotAttached) do
      shared.alias_attached!(network: "kamal", client: FakeDocker.new(%w[something-else]))
    end
    assert_nil shared.reload.network_alias_attached_at
    assert_equal "typed-name", shared.connect_host, "must still reach the name that works"
  end

  # The point of the keyword being optional: with nothing supplied it goes and looks.
  test "with nothing supplied it reads the aliases off the container" do
    shared = cluster("typed-name")
    looked = FakeDocker.new([ shared.resource_key ])

    shared.alias_attached!(network: "kamal", client: looked)

    assert_equal [ "typed-name", "kamal" ], looked.asked
    assert shared.reload.network_alias_attached_at
  end

  test "what the container reports, not what the caller hoped, decides" do
    shared = cluster("typed-name")

    assert_raises(DatabaseCluster::AliasNotAttached) do
      shared.alias_attached!(network: "kamal", client: FakeDocker.new([]))
    end
  end

  # An alias on network A must not certify the hostname for an app on network B —
  # the timestamp alone said "attached", and every app then got a name Docker could
  # not resolve from where it actually runs.
  test "an alias certifies only the network it was observed on" do
    shared = cluster("typed-name")
    shared.alias_attached!(network: "kamal", client: FakeDocker.new([ shared.resource_key ]))

    assert_equal shared.resource_key, shared.connect_host(network: "kamal")
    assert_equal "typed-name", shared.connect_host(network: "some-other-net")
  end

  class FakeDocker
    attr_reader :asked
    def initialize(aliases) = (@aliases = aliases)
    def network_aliases(container_name:, network:)
      @asked = [ container_name, network ]
      @aliases
    end
  end

  test "an alias that is actually present is recorded" do
    shared = cluster("typed-name")
    shared.alias_attached!(network: "kamal", client: FakeDocker.new([ shared.resource_key ]))

    assert shared.reload.network_alias_attached_at
    assert_equal shared.resource_key, shared.connect_host
  end

  # A COLUMN NOTHING WRITES FIXES NOTHING. Both production paths that create a
  # cluster record must declare what they made, or the inference stays in charge and
  # the defect is unchanged.
  test "Conductor records the cluster it creates as dedicated" do
    app = app_for("declared")
    app.update!(database_mode: "dedicated", database_placement: "colocated")
    DedicatedDbProvisioner.new(app: app, server: @server,
                               sql_client: FakeSql.new, container_client: FakeContainers.new).provision!

    cluster = @org.database_clusters.find_by(container_name: app.dedicated_db_container_name)
    assert_equal "dedicated", cluster.kind
  end

  test "registering an existing container records it as shared" do
    result = RegisterDatabaseClusterTool.new(user: @user).call(
      "name" => "ops-pg", "container_name" => "ops-pg", "server_id" => @server.id,
      "admin_username" => "conductor", "admin_password" => "s3cret"
    )

    assert result.success?, result.error
    assert_equal "shared", DatabaseCluster.find(result.value[:id]).kind
  end

  # A one-tenant SHARED cluster is indistinguishable from a dedicated one by
  # inference alone, so the kind an operator declared has to be recorded and win.
  test "a cluster registered as shared is never inferred to be dedicated" do
    app = app_for("solo")
    shared = cluster(app.dedicated_db_container_name)
    shared.update!(kind: "shared")
    shared.provision_database!(name: app.database_name, app: app, client: FakeSql.new)

    assert_not shared.assigned_container_name?
  end

  test "a cluster Conductor created is recorded as dedicated, not guessed" do
    app = app_for("solo")
    dedicated = cluster(app.dedicated_db_container_name)
    dedicated.update!(kind: "dedicated")

    assert dedicated.assigned_container_name?, "no databases yet, but the kind is known"
  end

  class FakeSql
    def create_database(*) = true
    def create_role(*) = true
  end

  class FakeContainers
    def create!(**) = { "action" => "created" }
  end
end
