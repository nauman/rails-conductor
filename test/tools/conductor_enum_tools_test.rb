require "test_helper"

# The six consolidated `action`-enum tools (18→7 consolidation). Each delegates
# to the existing single-purpose implementation classes via EnumDispatch. These
# tests cover the dispatch wiring (right action → right handler, params passed
# through), the legible error path, and registration. The underlying behaviour
# is already covered by the per-tool tests.
class ConductorEnumToolsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  test "ACTIONS maps unset_env to UnsetEnvVariableTool" do
    assert_equal UnsetEnvVariableTool, ConductorAppConfigTool::ACTIONS["unset_env"]
  end

  test "ACTIONS maps harden to HardenServerTool" do
    assert_equal HardenServerTool, ConductorServerTool::ACTIONS["harden"]
  end

  test "ACTIONS maps reboot to RebootServerTool" do
    assert_equal RebootServerTool, ConductorServerTool::ACTIONS["reboot"]
  end

  test "ACTIONS maps server (detail) to ServerDetailTool" do
    assert_equal ServerDetailTool, ConductorReadTool::ACTIONS["server"]
  end

  test "conductor_read action=server probe:false returns the full stored detail, no live probes" do
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    server = @org.servers.create!(name: "box6", status: "online", ip_address: "192.0.2.6",
                                  ssh_key: key, ssh_user: "deploy", edge_type: "kamal_proxy",
                                  last_harden_status: "succeeded", last_update_status: "succeeded")
    server.apps.create!(name: "App", deploy_method: "docker", domain: "app.example.com")

    # Default (no probe) is the fast stored summary — no live SSH.
    res = ConductorReadTool.new(user: @user).call("action" => "server", "server_id" => server.id)
    assert res.success?, res.error
    v = res.value
    assert_equal "box6", v[:name]
    assert v[:metrics].is_a?(Hash), "metrics block present"
    assert_equal "deploy", v[:ssh][:user]
    assert_equal "kamal_proxy", v[:edge][:type]
    assert_equal "succeeded", v[:harden][:last_status]
    assert_equal "app.example.com", v[:apps].first[:domain]
    assert v[:audit].key?(:last_status), "stored audit rollup present without a live probe"
    refute v.key?(:live), "default must skip the live SSH probes (no 504 risk)"
  end

  test "conductor_server action=harden enqueues a background job and returns immediately" do
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    server = @org.servers.create!(name: "box6", status: "online", ip_address: "192.0.2.6",
                                  ssh_key: key, ssh_user: "root")

    assert_enqueued_with(job: HardenServerJob, args: [ server.id ]) do
      res = ConductorServerTool.new(user: @user).call("action" => "harden", "server_id" => server.id)
      assert res.success?, res.error
      assert_equal "running", res.value[:status]
    end
    assert_equal "running", server.reload.last_harden_status
  end

  test "conductor_app_config action=unset_env removes the env var" do
    app = @org.apps.create!(name: "Appone", deploy_method: "docker")
    app.env_variables.create!(key: "DATABASE_URL", value: "postgres://old", secret: true)

    res = ConductorAppConfigTool.new(user: @user).call(
      "action" => "unset_env", "app_id" => app.id, "key" => "DATABASE_URL"
    )
    assert res.success?, res.error
    assert_equal true, res.value[:deleted]
    assert_not app.env_variables.exists?(key: "DATABASE_URL"), "var should be gone"
  end

  test "conductor_app_config action=unset_env is idempotent for an absent key" do
    app = @org.apps.create!(name: "Appone", deploy_method: "docker")
    res = ConductorAppConfigTool.new(user: @user).call(
      "action" => "unset_env", "app_id" => app.id, "key" => "NOPE"
    )
    assert res.success?, res.error
    assert_equal false, res.value[:deleted]
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
