require "test_helper"

# The six consolidated `action`-enum tools (18→7 consolidation). Each delegates
# to the existing single-purpose implementation classes via EnumDispatch. These
# tests cover the dispatch wiring (right action → right handler, params passed
# through), the legible error path, and registration. The underlying behaviour
# is already covered by the per-tool tests.
class ConductorEnumToolsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "enum@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
  end

  # --- ACTIONS maps to the expected handlers ----------------------------

  test "ACTIONS maps each action to its implementation class" do
    assert_equal CreateAppTool, ConductorAppTool::ACTIONS["create"]
    assert_equal DeployAppTool, ConductorAppTool::ACTIONS["deploy"]
    assert_equal SetEnvVariableTool, ConductorAppConfigTool::ACTIONS["set_env"]
    assert_equal RegisterServerTool, ConductorServerTool::ACTIONS["register"]
    assert_equal ProvisionDatabaseTool, ConductorDatabaseTool::ACTIONS["provision"]
    assert_equal AddDomainTool, ConductorDomainTool::ACTIONS["add"]
    assert_equal SetGithubTokenTool, ConductorGithubTool::ACTIONS["set_token"]
  end

  # --- real delegation (no external services) ---------------------------

  test "conductor_app action=create delegates to CreateAppTool" do
    res = ConductorAppTool.new(user: @user).call(
      "action" => "create", "name" => "Appone",
      "repository_url" => "git@github.com:me/appone.git", "deploy_method" => "docker"
    )
    assert res.success?, res.error
    assert_equal "appone", res.value[:slug]
  end

  test "conductor_app action=deploy is blocked by a held preflight, and force (string key) overrides" do
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                  ssh_key: key, ssh_user: "deploy")
    app = @org.apps.create!(name: "Appone", server: server, deploy_method: "kamal",
                            repository_url: "https://github.com/me/appone.git",
                            deploy_hold: true, deploy_hold_reason: "thread owed")

    blocked = ConductorAppTool.new(user: @user).call("action" => "deploy", "app_id" => app.id)
    assert blocked.success?, blocked.error
    assert_equal "blocked", blocked.value[:status]

    # MCP payloads are string-keyed — force must be read as "force", not :force.
    forced = ConductorAppTool.new(user: @user).call("action" => "deploy", "app_id" => app.id, "force" => true)
    assert_equal "started", forced.value[:status], "force:true (string key) must override the block"
  end

  test "conductor_app action=deploy rejects a non-boolean force instead of coercing it to true" do
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.11",
                                  ssh_key: key, ssh_user: "deploy")
    app = @org.apps.create!(name: "Apptwo", server: server, deploy_method: "kamal",
                            repository_url: "https://github.com/me/apptwo.git", deploy_hold: true)

    %w[banana no 0].each do |bad|
      res = ConductorAppTool.new(user: @user).call("action" => "deploy", "app_id" => app.id, "force" => bad)
      refute res.success?, "force=#{bad.inspect} must be rejected, not coerced to true"
      assert_match(/force/i, res.error)
    end
    # and the block still stands (nothing was force-deployed)
    assert_equal 0, app.deployments.where.not(status: "blocked").count
  end

  test "conductor_server action=register delegates to RegisterServerTool" do
    res = ConductorServerTool.new(user: @user).call(
      "action" => "register", "name" => "web-1", "ip_address" => "10.0.0.5", "ssh_user" => "deploy"
    )
    assert res.success?, res.error
    assert_equal @org, Server.find(res.value[:id]).organization
  end

  test "conductor_app_config action=set_env delegates to SetEnvVariableTool" do
    app = @org.apps.create!(name: "Appone", deploy_method: "docker")
    res = ConductorAppConfigTool.new(user: @user).call(
      "action" => "set_env", "app_id" => app.id, "key" => "RAILS_ENV", "value" => "production"
    )
    assert res.success?, res.error
    assert_equal "production", app.env_variables.find_by(key: "RAILS_ENV").value
  end

  test "conductor_database action=register_cluster delegates to RegisterDatabaseClusterTool" do
    @org.servers.create!(name: "db-host", status: "offline")
    res = ConductorDatabaseTool.new(user: @user).call(
      "action" => "register_cluster", "server_name" => "db-host", "name" => "shared",
      "container_name" => "conductor-postgres", "admin_username" => "conductor", "admin_password" => "pw"
    )
    assert res.success?, res.error
    assert_equal "shared", DatabaseCluster.find(res.value[:id]).name
  end

  # --- error path -------------------------------------------------------

  test "missing action returns a legible error listing valid actions" do
    res = ConductorAppTool.new(user: @user).call({})
    assert res.failure?
    assert_match(/action/, res.error)
    assert_match(/create/, res.error)
  end

  test "unknown action fails cleanly and echoes the bad value" do
    res = ConductorDomainTool.new(user: @user).call("action" => "bogus")
    assert res.failure?
    assert_match(/bogus/, res.error)
  end

  # --- registry & scope -------------------------------------------------

  test "the consolidated enum tools are registered" do
    names = ToolRegistry.definitions.map { |d| d[:name] }
    %w[conductor_app conductor_app_config conductor_server conductor_database
       conductor_domain conductor_github conductor_runbook conductor_storage].each { |n| assert_includes names, n }
  end

  test "mutating enum tools are NOT read-only allowed" do
    %w[conductor_app conductor_app_config conductor_server conductor_database
       conductor_domain conductor_github conductor_runbook conductor_storage].each do |n|
      refute_includes ToolRegistry::READ_ONLY_TOOLS, n
    end
  end
end
