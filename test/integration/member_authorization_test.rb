require "test_helper"

# Privileged operations (script management, running scripts/updates on servers)
# are owner/admin only — a plain member must not get infra execution.
class MemberAuthorizationTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @owner = User.create!(email: "owner@example.com")
    @org = Organization.create_for(@owner, name: "Acme")
    @member = User.create!(email: "member@example.com")
    @org.add_member(@member, role: :member)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @script = Script.create!(name: "danger", body: "echo hi", script_type: "provision")
  end

  test "a plain member cannot create a script" do
    sign_in_as(@member)
    assert_no_difference -> { Script.count } do
      post scripts_path, params: { script: { name: "evil", body: "echo pwned", script_type: "provision" } }
    end
    assert_redirected_to root_path
  end

  test "a plain member cannot run a script on a server (provision)" do
    sign_in_as(@member)
    assert_no_difference -> { ScriptRun.count } do
      post provision_server_path(@server), params: { script_id: @script.id }
    end
    assert_redirected_to root_path
  end

  test "a plain member cannot apply OS updates" do
    sign_in_as(@member)
    post apply_updates_server_path(@server), params: { scope: "security" }
    assert_redirected_to root_path
    assert_nil @server.reload.last_update_status
  end

  test "a plain member cannot create an app (equivalent execution path)" do
    sign_in_as(@member)
    assert_no_difference -> { App.count } do
      post apps_path, params: { app: { name: "Evil", slug: "evil", deploy_method: "docker",
                                       repository_url: "https://github.com/m/e.git", server_id: @server.id } }
    end
    assert_response :redirect
  end

  test "a plain member's self-minted MCP token is capped to read scope" do
    sign_in_as(@member)
    post mcp_tokens_path, params: { name: "t", scope: "deploy" }
    token = @member.api_tokens.where(organization: @org).order(:created_at).last
    assert_equal "read", token.scope, "a member must not be able to mint a deploy (execution) token"
  end

  test "a plain member cannot open the credentials page (decrypted secrets)" do
    sign_in_as(@member)
    get credentials_path
    assert_response :redirect
  end

  test "a plain member cannot open an SSH key edit page (would prefill the private key)" do
    key = @org.ssh_keys.create!(name: "k", private_key: valid_private_key)
    sign_in_as(@member)
    get edit_ssh_key_path(key)
    assert_response :redirect
  end

  test "an owner CAN open the credentials page" do
    sign_in_as(@owner)
    get credentials_path
    assert_response :success
  end

  test "an owner can create a script (owned by their org)" do
    sign_in_as(@owner)
    assert_difference -> { Script.count }, 1 do
      post scripts_path, params: { script: { name: "legit", body: "echo ok", script_type: "provision" } }
    end
    assert_equal @org, Script.find_by(name: "legit").organization
  end

  test "an org owner (non-admin) cannot edit a built-in script" do
    builtin = Script.create!(name: "test-builtin", body: "echo built", script_type: "provision", built_in: true)
    sign_in_as(@owner) # owner of @org, not a platform admin
    patch script_path(builtin), params: { script: { body: "echo pwned" } }
    assert_redirected_to scripts_path
    assert_equal "echo built", builtin.reload.body, "built-ins are admin-only, must not change"
  end

  test "an org owner cannot edit another org's script (404)" do
    other = Organization.create!(name: "Other Script Org")
    theirs = other.scripts.create!(name: "theirs", body: "echo theirs", script_type: "provision")
    sign_in_as(@owner)
    patch script_path(theirs), params: { script: { body: "echo pwned" } }
    assert_response :not_found
    assert_equal "echo theirs", theirs.reload.body
  end

  test "a platform admin CAN edit a built-in script" do
    builtin = Script.create!(name: "test-builtin2", body: "echo built", script_type: "provision", built_in: true)
    admin = User.create!(email: "admin@example.com", admin: true)
    admin.ensure_personal_organization!
    sign_in_as(admin)
    patch script_path(builtin), params: { script: { body: "echo updated" } }
    assert_equal "echo updated", builtin.reload.body
  end

  test "an owner can create an app" do
    sign_in_as(@owner)
    assert_difference -> { App.count }, 1 do
      post apps_path, params: { app: { name: "Legit", slug: "legit", deploy_method: "docker",
                                       repository_url: "https://github.com/o/a.git", server_id: @server.id } }
    end
  end
end
