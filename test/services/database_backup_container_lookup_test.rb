require "test_helper"

# THE BUG THIS EXISTS FOR. A docker-method app's backup resolved its container by
# a hardcoded name, `conductor-<slug>`. When that app moved to the ADR 0004 stable
# resource names on a deploy, the name stopped matching, so `docker exec` found
# nothing, DATABASE_URL resolved to nil, and pg_dump fell back to a local unix
# socket that does not exist:
#
#   pg_dump: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed
#
# It had verified clean five days earlier with a real restore. The backup did not
# break — the app moved out from under it, silently, and three nights failed before
# anyone asked. The kamal branch never had this problem because it has always
# resolved by LABEL.
class DatabaseBackupContainerLookupTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "lookup@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.4")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "docker",
                             port: 3000, repository_url: "https://github.com/x/y.git")
    @backup = @org.backups.create!(app: @app, server: @server, provider: "cloudflare_r2",
                                   bucket_name: "mybucket", status: "pending",
                                   credential: @org.credentials.create!(name: "c", provider: "cloudflare",
                                                                        api_key: "AK", api_secret: "SK"))
  end

  def source = DatabaseBackup.new(@backup).send(:dump_source_container, @app)

  test "a docker app is found by its service label, like every kamal app already is" do
    assert_includes source, "label=service=#{@app.resource_key}"
    assert_includes source, "label=role=web"
  end

  # Identity is ASSIGNED (ADR 0004) — `app-<id>` survives a rename, a redeploy and
  # a change of container-naming scheme. The old fixed name survives none of those.
  test "the lookup uses the stable resource key, not the slug-derived name" do
    assert_includes source, "app-#{@app.id}"
  end

  # Containers predating the labels still exist on boxes, so the old name stays as
  # a FALLBACK — but only when the label finds nothing.
  test "the legacy fixed name remains as a fallback" do
    assert_includes source, @app.container_name,
                    "a container from before the labels must still be findable"
  end

  test "kamal apps keep resolving by label, unchanged" do
    @app.update!(deploy_method: "kamal")

    assert_includes source, "label=service="
    assert_includes source, "role=web"
  end

  test "a native app has no container to dump from" do
    @app.update!(deploy_method: "native")

    assert_nil source
  end
end
