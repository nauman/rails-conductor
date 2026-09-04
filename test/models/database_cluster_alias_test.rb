require "test_helper"

# `Database#database_url` used `database_cluster.container_name` as its HOST — a
# mutable display column doing double duty as the DNS name every dependent app
# resolves. Renaming a cluster silently broke the next deploy of every app on it,
# and the transfer path (source and target on different hosts, live data in flight)
# derived both ends from names a human typed.
#
# ADR 0011: identity is ASSIGNED. A cluster gets `cluster-<id>` as a network alias,
# and that is what the URL points at, so a rename becomes cosmetic.
class DatabaseClusterAliasTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "dca@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.41")
    @cluster = @org.database_clusters.create!(server: @server, name: "shared", container_name: "conductor-postgres",
                                              admin_username: "postgres", admin_password: "pw")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
  end

  def database = @cluster.databases.create!(organization: @org, app: @app, name: "shop_production",
                                            username: "shop", password: "pw", status: "active")

  test "a cluster's assigned identity is derived from its id, never its name" do
    assert_equal "cluster-#{@cluster.id}", @cluster.resource_key
  end

  test "renaming the container does not change the assigned identity" do
    before = @cluster.resource_key
    @cluster.update!(container_name: "renamed-postgres", name: "Renamed")

    assert_equal before, @cluster.reload.resource_key
  end

  # THE POINT. The URL must survive a rename, because the app re-derives it on the
  # next deploy and would otherwise resolve a host that no longer exists.
  # MIGRATION GATE. Switching the host before the alias exists would break every app
  # on a shared cluster at its next deploy — all at once, and worse than the rename
  # it prevents. The typed name stays until an operator attaches the alias.
  test "a shared cluster keeps its typed name until the alias is actually attached" do
    assert_equal "conductor-postgres", @cluster.connect_host
    assert_includes database.database_url, "@conductor-postgres:"
  end

  test "a SHARED cluster's URL uses the assigned alias, not the typed name" do
    @cluster.alias_attached!
    url = database.reload.database_url

    assert_includes url, "@cluster-#{@cluster.id}:"
    assert_not_includes url, "conductor-postgres", "an operator-typed name must not be the DNS host"
  end

  # A dedicated cluster's container name is ALREADY assigned (app-<id>-db), so it is
  # stable by construction. Aliasing it would change the host of every existing
  # dedicated database for no gain — which the first version of this did, and the
  # existing tests caught.
  # BOTH dedicated spellings count. The stable `app-<id>-db` and the legacy
  # `<slug>-db` are equally Conductor-assigned, and App#dedicated_db_container_candidates
  # is what says so — pattern-matching the name's shape missed the legacy one and
  # would have re-hosted an already-stable cluster.
  test "a DEDICATED cluster keeps its already-assigned container name, either spelling" do
    [ "app-#{@app.id}-db", "#{@app.slug}-db" ].each do |assigned|
      cluster = @org.database_clusters.create!(server: @server, name: "d-#{assigned}", container_name: assigned,
                                               admin_username: "postgres", admin_password: "pw")
      cluster.databases.create!(organization: @org, app: @app, name: "d", username: "u", password: "p", status: "active")

      assert cluster.assigned_container_name?, "#{assigned} is Conductor-assigned"
      assert_equal assigned, cluster.reload.connect_host
    end
  end

  test "the URL survives a container rename unchanged" do
    @cluster.alias_attached!
    db = database
    before = db.database_url
    @cluster.update!(container_name: "something-else")

    assert_equal before, db.reload.database_url
  end

  # Registration must attach the alias, or the URL names something Docker cannot
  # resolve — a worse failure than the one being fixed, because it breaks on day one
  # rather than at the next rename.
  test "the alias flag is what registration attaches" do
    assert_includes @cluster.network_alias_args, "--alias"
    assert_includes @cluster.network_alias_args, @cluster.resource_key
  end
end
