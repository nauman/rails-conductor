require "test_helper"

class ApiOrgScopingTest < ActionDispatch::IntegrationTest
  setup do
    @user_a = User.create!(email: "a@example.com")
    @org_a = Organization.create_for(@user_a, name: "Org A")
    @user_a.organizations.update_all(onboarded_at: Time.current)

    @user_b = User.create!(email: "b@example.com")
    @org_b = Organization.create_for(@user_b, name: "Org B")
    @user_b.organizations.update_all(onboarded_at: Time.current)

    # Org A resources
    @server_a = @org_a.servers.create!(name: "server-a", status: "online")
    @app_a = @org_a.apps.create!(name: "app-a", slug: "app-a", status: "running")
    @backup_a = @org_a.backups.create!(provider: "aws_s3", bucket_name: "bucket-a", enabled: true)

    # Org B resources
    @server_b = @org_b.servers.create!(name: "server-b", status: "offline")
    @app_b = @org_b.apps.create!(name: "app-b", slug: "app-b", status: "stopped")
    @backup_b = @org_b.backups.create!(provider: "aws_s3", bucket_name: "bucket-b", enabled: false)

    @raw_a, = ApiToken.generate(user: @user_a, name: "tok-a", organization: @org_a)
  end

  def auth(raw_token)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  def json
    JSON.parse(@response.body)
  end

  # --- Reads: own org succeeds ---

  test "token can read its own org's server" do
    get api_v1_server_path(@server_a), headers: auth(@raw_a)
    assert_response :success
    assert_equal "server-a", json["name"]
  end

  test "servers index lists only the caller's org" do
    get api_v1_servers_path, headers: auth(@raw_a)
    assert_response :success
    names = json.map { |s| s["name"] }
    assert_includes names, "server-a"
    assert_not_includes names, "server-b"
  end

  test "apps index lists only the caller's org" do
    get api_v1_apps_path, headers: auth(@raw_a)
    assert_response :success
    names = json.map { |a| a["name"] }
    assert_includes names, "app-a"
    assert_not_includes names, "app-b"
  end

  test "backups index lists only the caller's org" do
    get api_v1_backups_path, headers: auth(@raw_a)
    assert_response :success
    buckets = json.map { |b| b["bucket_name"] }
    assert_includes buckets, "bucket-a"
    assert_not_includes buckets, "bucket-b"
  end

  # --- Cross-org reads: 404 ---

  test "token cannot read another org's server" do
    get api_v1_server_path(@server_b), headers: auth(@raw_a)
    assert_response :not_found
  end

  test "token cannot read another org's app" do
    get api_v1_app_path(@app_b), headers: auth(@raw_a)
    assert_response :not_found
  end

  test "token cannot read another org's backup" do
    get api_v1_backup_path(@backup_b), headers: auth(@raw_a)
    assert_response :not_found
  end

  # --- Cross-org mutations: 404 ---

  test "token cannot provision another org's server" do
    post provision_api_v1_server_path(@server_b), headers: auth(@raw_a)
    assert_response :not_found
  end

  test "token cannot deploy another org's app" do
    post deploy_api_v1_app_path(@app_b), headers: auth(@raw_a)
    assert_response :not_found
  end

  test "token cannot run another org's backup" do
    post run_api_v1_backup_path(@backup_b), headers: auth(@raw_a)
    assert_response :not_found
  end

  test "scripts run cannot target another org's server" do
    script = Script.create!(name: "echo", script_type: "setup", body: "echo hi")
    assert_no_difference -> { ScriptRun.count } do
      post run_api_v1_scripts_path,
        params: { script_id: script.id, server_id: @server_b.id },
        headers: auth(@raw_a)
    end
    assert_response :not_found
  end

  test "scripts run works on caller's own server" do
    script = Script.create!(name: "echo2", script_type: "setup", body: "echo hi")
    assert_difference -> { ScriptRun.count }, 1 do
      post run_api_v1_scripts_path,
        params: { script_id: script.id, server_id: @server_a.id },
        headers: auth(@raw_a)
    end
    assert_response :created
  end

  # --- Status counts are org-scoped ---

  test "status reports only the caller's org counts" do
    get api_v1_status_path, headers: auth(@raw_a)
    assert_response :success
    assert_equal 1, json["servers"]["total"]
    assert_equal 1, json["apps"]["total"]
    assert_equal 1, json["backups"]["total"]
  end

  # --- Create assigns to caller's org ---

  test "creating a server assigns it to the caller's org" do
    assert_difference -> { @org_a.servers.count }, 1 do
      post api_v1_servers_path, params: { server: { name: "fresh", status: "offline" } }, headers: auth(@raw_a)
    end
    assert_response :created
    assert_equal @org_a.id, Server.find(json["id"]).organization_id
  end

  # --- Org-less token falls back to user's first org ---

  test "org-less token falls back to the user's first org" do
    raw, = ApiToken.generate(user: @user_a, name: "no-org")
    get api_v1_server_path(@server_a), headers: auth(raw)
    assert_response :success
    assert_equal "server-a", json["name"]
  end

  test "token for a user with no org gets a 403" do
    orphan = User.create!(email: "orphan@example.com")
    # Strip any auto-created org to simulate an org-less user.
    orphan.memberships.destroy_all
    raw, = ApiToken.generate(user: orphan, name: "orphan-tok")
    get api_v1_servers_path, headers: auth(raw)
    assert_response :forbidden
  end
end
