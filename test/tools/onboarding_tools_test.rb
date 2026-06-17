require "test_helper"

# Covers the MCP tools that mirror the web UI's full app-onboarding workflow:
# register server → register cluster → provision database → create app → set env.
class OnboardingToolsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "mcp-admin@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
  end

  # --- register_server ---------------------------------------------------

  test "register_server creates a server in the user's default org" do
    result = RegisterServerTool.new(user: @user).call(
      "name" => "web-1", "ip_address" => "10.0.0.5", "ssh_user" => "deploy"
    )

    assert result.success?, result.error
    server = Server.find(result.value[:id])
    assert_equal @org, server.organization
    assert_equal "deploy", server.ssh_user
    assert_equal @org, result.value[:_organization]
  end

  test "register_server resolves organization by slug (parameterized name)" do
    other = Organization.create_for(@user, name: "Beta Corp")
    result = RegisterServerTool.new(user: @user).call(
      "name" => "web-2", "ip_address" => "10.0.0.6",
      "ssh_user" => "deploy", "organization_slug" => "beta-corp"
    )

    assert result.success?, result.error
    assert_equal other, Server.find(result.value[:id]).organization
  end

  test "register_server fails on blank name" do
    result = RegisterServerTool.new(user: @user).call("ip_address" => "1.2.3.4", "ssh_user" => "deploy")
    assert result.failure?
  end

  # --- register_database_cluster ----------------------------------------

  test "register_database_cluster creates a cluster on a server by name" do
    @org.servers.create!(name: "db-host", status: "offline")
    result = RegisterDatabaseClusterTool.new(user: @user).call(
      "server_name" => "db-host", "name" => "shared",
      "container_name" => "conductor-postgres",
      "admin_username" => "conductor", "admin_password" => "pw", "port" => 5432
    )

    assert result.success?, result.error
    cluster = DatabaseCluster.find(result.value[:id])
    assert_equal "shared", cluster.name
    assert_equal @org, result.value[:_organization]
  end

  test "register_database_cluster fails when server not found" do
    result = RegisterDatabaseClusterTool.new(user: @user).call(
      "server_name" => "nope", "name" => "shared",
      "container_name" => "c", "admin_username" => "u", "admin_password" => "p"
    )
    assert result.failure?
  end

  # --- provision_database -----------------------------------------------

  test "provision_database provisions on a cluster and returns a url" do
    server = @org.servers.create!(name: "db-host2", status: "offline")
    cluster = @org.database_clusters.create!(
      server: server, name: "shared", container_name: "conductor-postgres",
      admin_username: "conductor", admin_password: "pw"
    )
    fake = Object.new
    def fake.create_database(**) = { "action" => "created" }

    PostgresClusterClient.stub(:new, fake) do
      result = ProvisionDatabaseTool.new(user: @user).call(
        "cluster_name" => "shared", "name" => "kuickr_production", "username" => "kuickr"
      )
      assert result.success?, result.error
      assert_includes result.value[:database_url], "kuickr_production"
      assert_equal @org, result.value[:_organization]
    end
  end

  test "provision_database links to an app when app_id given" do
    server = @org.servers.create!(name: "db-host3", status: "offline")
    cluster = @org.database_clusters.create!(
      server: server, name: "shared", container_name: "c",
      admin_username: "u", admin_password: "p"
    )
    app = @org.apps.create!(name: "Kuickr", server: server, deploy_method: "docker")
    fake = Object.new
    def fake.create_database(**) = { "action" => "created" }

    PostgresClusterClient.stub(:new, fake) do
      result = ProvisionDatabaseTool.new(user: @user).call(
        "cluster_id" => cluster.id, "name" => "k_prod", "app_id" => app.id
      )
      assert result.success?, result.error
      assert_equal app, Database.find(result.value[:id]).app
    end
  end

  test "provision_database fails when cluster not found" do
    result = ProvisionDatabaseTool.new(user: @user).call("cluster_name" => "ghost", "name" => "x")
    assert result.failure?
  end

  # --- create_app --------------------------------------------------------

  test "create_app creates an app with notes on a server" do
    @org.servers.create!(name: "app-host", status: "offline")
    result = CreateAppTool.new(user: @user).call(
      "name" => "Kuickr", "repository_url" => "git@github.com:me/kuickr.git",
      "server_name" => "app-host", "deploy_method" => "docker",
      "domain" => "kuickr.co", "port" => 3000, "notes" => "deploy via kamal"
    )

    assert result.success?, result.error
    app = App.find(result.value[:id])
    assert_equal "kuickr", app.slug
    assert_equal "deploy via kamal", app.notes
    assert_equal @org, result.value[:_organization]
    assert_equal "kuickr", result.value[:slug]
  end

  test "create_app rejects invalid deploy_method" do
    result = CreateAppTool.new(user: @user).call(
      "name" => "Bad", "repository_url" => "x", "deploy_method" => "kubernetes"
    )
    assert result.failure?
  end

  # --- set_env_variable --------------------------------------------------

  test "set_env_variable upserts a variable on an app by name" do
    app = @org.apps.create!(name: "Kuickr", deploy_method: "docker")

    created = SetEnvVariableTool.new(user: @user).call(
      "app_name" => "Kuickr", "key" => "RAILS_ENV", "value" => "production"
    )
    assert created.success?, created.error
    assert_equal "production", app.env_variables.find_by(key: "RAILS_ENV").value
    assert_equal @org, created.value[:_organization]

    updated = SetEnvVariableTool.new(user: @user).call(
      "app_id" => app.id, "key" => "RAILS_ENV", "value" => "staging"
    )
    assert updated.success?, updated.error
    assert_equal 1, app.env_variables.where(key: "RAILS_ENV").count
    assert_equal "staging", app.env_variables.find_by(key: "RAILS_ENV").value
  end

  test "set_env_variable fails on invalid key format" do
    @org.apps.create!(name: "Kuickr", deploy_method: "docker")
    result = SetEnvVariableTool.new(user: @user).call(
      "app_name" => "Kuickr", "key" => "lower-case", "value" => "x"
    )
    assert result.failure?
  end

  test "set_env_variable fails when app not found" do
    result = SetEnvVariableTool.new(user: @user).call("app_name" => "ghost", "key" => "X", "value" => "y")
    assert result.failure?
  end

  # --- registry ----------------------------------------------------------

  test "all new tools are registered" do
    names = ToolRegistry.definitions.map { |d| d[:name] }
    %w[register_server register_database_cluster provision_database create_app set_env_variable].each do |n|
      assert_includes names, n
    end
  end
end
