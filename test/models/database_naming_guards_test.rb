require "test_helper"

# Six findings from an adversarial audit of the naming/identity work. Every one is a
# way a name can look legal and be wrong, which is the only interesting kind of
# naming bug — an obviously-bad name fails loudly at CREATE DATABASE.
class DatabaseNamingGuardsTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "dng@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.50")
  end

  def app_for(slug)
    @org.apps.create!(name: slug, slug: slug, server: @server, deploy_method: "kamal",
                      port: 3000, repository_url: "https://github.com/x/y.git")
  end

  # POSTGRES TRUNCATES AT 63 BYTES. A long slug silently loses `_production`, and two
  # apps differing only after byte 63 collide on a name neither of them chose.
  test "a derived name never exceeds the 63-byte identifier limit" do
    app = app_for("a" * 80)

    assert_operator app.database_name.bytesize, :<=, 63
    assert_operator app.database_username.bytesize, :<=, 63
  end

  test "two long slugs that share a 63-byte prefix still get different names" do
    a = app_for("#{'x' * 70}-alpha")
    b = app_for("#{'x' * 70}-beta")

    assert_not_equal a.database_name, b.database_name, "truncation must not manufacture a collision"
  end

  # A slug like `select` passes a character-class regex and then collides with an
  # unquoted reserved keyword in CREATE ROLE.
  test "reserved words are escaped out of the way" do
    %w[select user table order group grant].each do |word|
      app = app_for(word)

      assert_not_equal word, app.database_username, "#{word} is a reserved keyword"
      assert_match(/\A[a-z_][a-z0-9_]*\z/, app.database_username)
    end
  end

  # `postgres` and `conductor` are existing administrative roles on the cluster.
  test "administrative role names are not reused" do
    %w[postgres conductor].each do |word|
      assert_not_equal word, app_for(word).database_username
    end
  end

  # The other half of that: names that merely LOOK administrative are legal, and
  # refusing them would turn a safety rule into an arbitrary one.
  test "legal identifiers are not refused for looking dangerous" do
    %w[users admin root].each do |word|
      assert_equal word, app_for(word).database_username, "#{word} is a legal identifier"
    end
  end

  # THE COLLISION. Three distinct, valid slugs collapse to one base — the second
  # CREATE ROLE fails and leaves an error row behind.
  test "slugs that collapse to the same base get distinct names" do
    names = %w[foo-bar foo_bar foo.bar].map { |s| app_for(s).database_name }

    assert_equal names.uniq.length, names.length, "distinct apps must not fight over one database"
  end

  # THE ORPHANING CASE. Once a database exists, the derivation has served its purpose
  # and the recorded name is the fact — re-deriving after a rename would point a
  # re-provision at a NEW empty database while the app's data sits in the old one.
  test "a provisioned app keeps the name it was actually given" do
    app = app_for("before")
    cluster = @org.database_clusters.create!(name: "c", container_name: "c", server: @server,
                                              admin_username: "conductor", admin_password: "x", port: 5432)
    cluster.provision_database!(name: app.database_name, username: app.database_username,
                                app: app, client: FakeSql.new)

    app.update!(slug: "after")

    assert_equal "before_production", app.reload.database_name
    assert_equal "before", app.database_username
  end

  class FakeSql
    def create_database(*) = true
    def create_role(*) = true
  end

  # A transfer REPLICATES a database; it does not rename it. So while only the source
  # exists the target must be told the SAME name — and once both exist, the server is
  # what tells them apart. An earlier version of this test asserted the opposite and
  # passed only because the two names happened to be equal.
  test "a transfer target is given the source's name, then they are told apart by server" do
    app = app_for("moving")
    target = @org.servers.create!(name: "target", status: "online", ip_address: "10.0.0.53")
    src = @org.database_clusters.create!(name: "src", container_name: "src", server: @server,
                                          admin_username: "conductor", admin_password: "x", port: 5432)
    dst = @org.database_clusters.create!(name: "dst", container_name: "dst", server: target,
                                          admin_username: "conductor", admin_password: "x", port: 5432)
    src.provision_database!(name: "moving_production", username: "moving_src", app: app, client: FakeSql.new)

    assert_equal "moving_src", app.database_username(server: target),
                 "only one database exists — the target is provisioned to match it"

    dst.provision_database!(name: "moving_production", username: "moving_dst", app: app, client: FakeSql.new)

    assert_equal "moving_src", app.database_username(server: @server)
    assert_equal "moving_dst", app.database_username(server: target)
  end

  # The memo must not outlive its input.
  test "renaming an unprovisioned app changes the name it will be given" do
    app = app_for("first")

    assert_equal "first_production", app.database_name

    app.update!(slug: "second")

    assert_equal "second_production", app.database_name
  end

  # THE FALLBACK NAMESPACE MUST BE DISJOINT. An app slugged `app-102` normalizes to
  # `app_102` — which is exactly what app 102 falls back to. A fallback that can be
  # derived is not a fallback.
  test "a slug cannot squat on another app's assigned name" do
    squatter = app_for("app-999999")

    assert_not_equal "app_999999", squatter.database_base_name
    assert_equal squatter.assigned_database_base_name, squatter.database_base_name
  end

  # A shared cluster on a DIFFERENT box than the app is the ordinary case, and the
  # app's database was invisible to a server-scoped lookup — so a rename re-derived.
  test "a database on another host still counts as the recorded name" do
    app = app_for("remote")
    db_host = @org.servers.create!(name: "dbbox", status: "online", ip_address: "10.0.0.60")
    cluster = @org.database_clusters.create!(name: "shared", container_name: "shared", server: db_host,
                                              admin_username: "conductor", admin_password: "x", port: 5432)
    cluster.provision_database!(name: "remote_production", username: "remote", app: app, client: FakeSql.new)

    app.update!(slug: "renamed")

    assert_equal "remote_production", app.reload.database_name
  end

  # Deriving a name must never be the thing that raises. An app without an
  # organization is unusual, not impossible, and this ran on every provisioning path.
  test "an app with no organization still derives a name" do
    orphan = App.new(name: "loose", slug: "loose", port: 3000)

    assert_nothing_raised { orphan.database_name }
  end

  test "the disambiguator is stable for a given app" do
    app = app_for("foo-bar")

    assert_equal app.database_name, app.reload.database_name
  end
end
