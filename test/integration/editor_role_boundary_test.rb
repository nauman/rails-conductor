require "test_helper"

# SC-009: the editor role is only real if the owner-only bands hold on EVERY
# surface. This walks the matrix on web, MCP, and API.
class EditorRoleBoundaryTest < ActionDispatch::IntegrationTest
  setup do
    @org = Organization.create!(name: "Acme")
    @owner = User.create!(email: "owner@example.com")
    @editor = User.create!(email: "editor@example.com")
    @member = User.create!(email: "member@example.com")
    @org.add_member(@owner, role: :owner)
    @org.add_member(@editor, role: :editor)
    @org.add_member(@member, role: :member)

    @web_app = @org.apps.create!(name: "shop", repository_url: "https://github.com/acme/shop", branch: "main")
  end

  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  # ---- web: owner-only destroy -------------------------------------------

  test "an editor cannot delete an app; an owner can" do
    sign_in_as(@editor)
    assert_no_difference -> { App.count } do
      delete app_path(@web_app)
    end
    assert_response :redirect
    assert_match(/owner/i, flash[:alert].to_s)
  end

  test "a member cannot delete an app either" do
    sign_in_as(@member)
    assert_no_difference -> { App.count } do
      delete app_path(@web_app)
    end
    assert_response :redirect
  end

  # ---- web: editors keep the ordinary operating surface -------------------

  test "an editor may update ordinary app config" do
    sign_in_as(@editor)
    patch app_path(@web_app), params: { app: { notes: "editor was here" } }

    assert_equal "editor was here", @web_app.reload.notes
  end

  test "an editor may change the branch but not repoint the repository" do
    sign_in_as(@editor)

    patch app_path(@web_app), params: { app: { branch: "hotfix" } }
    assert_equal "hotfix", @web_app.reload.branch

    patch app_path(@web_app), params: { app: { repository_url: "https://github.com/attacker/evil" } }
    assert_equal "https://github.com/acme/shop", @web_app.reload.repository_url
    assert_match(/repositor/i, flash[:alert].to_s)
  end

  test "an owner may repoint the repository" do
    sign_in_as(@owner)
    patch app_path(@web_app), params: { app: { repository_url: "https://github.com/acme/shop-v2" } }

    assert_equal "https://github.com/acme/shop-v2", @web_app.reload.repository_url
  end

  # ---- web: owner-only execute + credentials -----------------------------

  test "an editor cannot reach scripts, credentials, or ssh keys" do
    sign_in_as(@editor)

    [ scripts_path, credentials_path, ssh_keys_path ].each do |path|
      get path
      assert_response :redirect, "#{path} should be owner-only"
      assert_match(/owner/i, flash[:alert].to_s, "#{path} should explain why")
    end
  end

  test "an editor cannot toggle seed-on-next-deploy" do
    sign_in_as(@editor)
    patch toggle_seed_on_next_deploy_app_path(@web_app)

    assert_response :redirect
    assert_not @web_app.reload.seed_on_next_deploy
  end

  # ---- members ------------------------------------------------------------

  test "an owner can promote a member to editor" do
    sign_in_as(@owner)
    membership = @org.memberships.find_by(user: @member)
    patch member_path(membership), params: { role: "editor" }

    assert membership.reload.editor?
  end

  test "an editor cannot change roles" do
    sign_in_as(@editor)
    membership = @org.memberships.find_by(user: @member)
    patch member_path(membership), params: { role: "owner" }

    assert membership.reload.member?
    assert_match(/owner/i, flash[:alert].to_s)
  end

  test "the sole owner cannot demote themselves" do
    sign_in_as(@owner)
    membership = @org.memberships.find_by(user: @owner)
    patch member_path(membership), params: { role: "editor" }

    assert membership.reload.owner?
  end

  # ---- members page renders -----------------------------------------------

  test "the members page renders role controls for an owner and badges for others" do
    sign_in_as(@owner)
    get members_path
    assert_response :success
    assert_select "select[name=?]", "role", minimum: 3   # one per member row
    assert_select "option[value=?]", "editor"

    sign_in_as(@member)
    get members_path
    assert_response :success
    assert_select "select[name=?]", "role", count: 0
    assert_match(/editor/i, response.body)               # badge text still shown
  end

  test "the sole owner's role control is disabled" do
    sign_in_as(@owner)
    get members_path

    assert_select "select[name=?][disabled]", "role", count: 1
  end

  # ---- MCP tokens ---------------------------------------------------------

  test "an editor mints a deploy token; a member is told why they cannot" do
    sign_in_as(@editor)
    post mcp_tokens_path, params: { name: "agent", scope: "deploy" }
    assert_equal "deploy", ApiToken.where(user: @editor).last.scope

    sign_in_as(@member)
    post mcp_tokens_path, params: { name: "agent", scope: "deploy" }
    assert_equal "read", ApiToken.where(user: @member).last.scope
    assert_match(/editor role/i, flash[:notice].to_s)
  end
end
