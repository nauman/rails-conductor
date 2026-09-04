require "test_helper"

# TWO PROVISIONING PATHS DISAGREED. The UI derived `<base>_production` / `<base>`
# from the app; the MCP tool took a caller-supplied name and username with no
# default, so an agent provisioning a new app invented its own convention. The one
# most likely to provision a brand-new app is the one with no convention at all.
#
# A naming convention that only one caller follows is a preference, not a convention.
class DatabaseNamingConventionTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "dbn@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.40")
  end

  def app_for(slug)
    @org.apps.create!(name: slug.titleize, slug: slug, server: @server, deploy_method: "kamal",
                      port: 3000, repository_url: "https://github.com/x/y.git")
  end

  test "the convention is derived from the app, in one place" do
    app = app_for("my-app")

    assert_equal "my_app", app.database_base_name
    assert_equal "my_app_production", app.database_name
    assert_equal "my_app", app.database_username
  end

  test "a slug starting with a digit is prefixed — postgres identifiers cannot" do
    app = app_for("79-thing")

    assert_match(/\A[a-z_]/, app.database_name)
    assert_equal "app_79_thing_production", app.database_name
  end

  test "dots and dashes become underscores, not quoted identifiers" do
    app = app_for("some-site")

    assert_equal "some_site_production", app.database_name
    assert_not_includes app.database_name, "-"
  end

  # The names reach CREATE DATABASE / CREATE ROLE as interpolated SQL, so the
  # convention must produce something that passes the identifier guard by
  # construction rather than by luck.
  test "the derived names satisfy the identifier guard" do
    %w[my-app some.site 79-thing a upper-case].each do |slug|
      app = app_for(slug)

      assert_match PostgresClusterClient::IDENTIFIER, app.database_name, "#{slug} → #{app.database_name}"
      assert_match PostgresClusterClient::IDENTIFIER, app.database_username, "#{slug} → #{app.database_username}"
    end
  end
end
