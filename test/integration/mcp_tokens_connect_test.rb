require "test_helper"

# The MCP tokens page doubles as the "connect an agent" surface: it renders
# ready-to-paste config for every supported MCP client, and embeds a freshly
# minted token exactly once (at create time).
class McpTokensConnectTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "owner@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    sign_in_as(@user)
  end

  test "connect panel lists Claude, Cursor and Codex config with a placeholder token" do
    get mcp_tokens_path

    assert_response :success
    assert_select "h2", text: "Connect an agent"
    assert_includes response.body, "claude mcp add --transport http"
    assert_includes response.body, "~/.cursor/mcp.json"
    assert_includes response.body, "mcp-remote"          # Codex bridge recipe
    assert_includes response.body, "$CONDUCTOR_MCP_TOKEN" # placeholder, no real token
  end

  test "a freshly created token is embedded in the connect snippets, once" do
    post mcp_tokens_path, params: { name: "codex", scope: "read" }
    raw = flash[:new_token]
    assert raw.present?, "expected a raw token to be surfaced once"

    follow_redirect!
    # Codex + Claude + Cursor blocks each carry the real token for copy-paste.
    assert_operator response.body.scan(raw).size, :>=, 3
    assert_includes response.body, "mcp-remote"
  end
end
