require "test_helper"

class KamalEnvWriterTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "kew@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @app = @org.apps.create!(name: "Appone", slug: "appone", deploy_method: "kamal")
  end

  test "renders dotenv KEY=value lines sorted by key" do
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "abc123")
    @app.env_variables.create!(key: "DATABASE_URL", value: "postgres://u:p@h/db")

    content = KamalEnvWriter.secrets_content(@app)

    # sorted: DATABASE_URL before SECRET_KEY_BASE
    assert_equal "DATABASE_URL=postgres://u:p@h/db\nSECRET_KEY_BASE=abc123\n", content
    assert_equal %w[DATABASE_URL SECRET_KEY_BASE], KamalEnvWriter.managed_keys(@app)
  end

  test "empty when the app has no env vars" do
    assert_equal "\n", KamalEnvWriter.secrets_content(@app)
    assert_empty KamalEnvWriter.managed_keys(@app)
  end

  # --- Slice 3: derived DATABASE_URL for dedicated apps ----------------------

  def provision_dedicated_db!
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    server = @org.servers.create!(name: "s", status: "online", ip_address: "10.0.0.1",
                                  ssh_key: key, ssh_user: "deploy")
    @app.update!(server: server) # dedicated + colocated by default
    cluster = @org.database_clusters.create!(server: server, name: @app.dedicated_db_container_name,
                                             container_name: @app.dedicated_db_container_name,
                                             admin_username: "conductor", admin_password: "x", port: 5432)
    cluster.databases.create!(organization: @org, app: @app, name: "appone", username: "appone",
                              password: "pw", status: "active")
  end

  test "injects DATABASE_URL from the provisioned dedicated DB (Decision B)" do
    provision_dedicated_db!
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "abc123")

    content = KamalEnvWriter.secrets_content(@app)

    assert_includes content, "DATABASE_URL=postgres://appone:pw@appone-db:5432/appone\n"
    assert_includes KamalEnvWriter.managed_keys(@app), "DATABASE_URL"
  end

  test "an explicit DATABASE_URL env var overrides the derived one" do
    provision_dedicated_db!
    @app.env_variables.create!(key: "DATABASE_URL", value: "postgres://override@elsewhere/db")

    content = KamalEnvWriter.secrets_content(@app)

    assert_includes content, "DATABASE_URL=postgres://override@elsewhere/db\n"
    refute_includes content, "appone-db"
    assert_equal 1, content.scan("DATABASE_URL=").size, "no duplicate DATABASE_URL line"
  end

  test "shared-mode apps get no derived DATABASE_URL" do
    provision_dedicated_db!
    @app.update!(database_mode: "shared")

    refute_includes KamalEnvWriter.managed_keys(@app), "DATABASE_URL"
  end
end
