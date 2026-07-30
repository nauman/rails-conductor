require "test_helper"

# OAuth 2.1 connect flow for the MCP endpoint (spec 06): an MCP client discovers
# the authorization server, registers itself, sends the user through a browser
# authorize step, and exchanges the code for a token /mcp accepts. This is what
# lets Codex / claude.ai / Cursor offer "Connect" instead of asking the user to
# paste a bearer token.
class McpOauthConnectTest < ActionDispatch::IntegrationTest
  REDIRECT_URI = "http://127.0.0.1:52100/callback".freeze # Codex-style loopback
  VERIFIER = "a" * 64

  setup do
    @user = User.create!(email: "owner@example.com")
    @org = Organization.create_for(@user, name: "Org A")
    @other_user = User.create!(email: "stranger@example.com")
    @other_org = Organization.create_for(@other_user, name: "Org B")
  end

  # --- discovery ------------------------------------------------------------

  test "authorization server metadata advertises the endpoints a client needs" do
    get "/.well-known/oauth-authorization-server"
    assert_response :success
    doc = JSON.parse(response.body)

    assert_equal "http://www.example.com/oauth/authorize", doc["authorization_endpoint"]
    assert_equal "http://www.example.com/oauth/token", doc["token_endpoint"]
    assert_equal "http://www.example.com/oauth/register", doc["registration_endpoint"]
    assert_equal %w[S256], doc["code_challenge_methods_supported"], "OAuth 2.1: no plain PKCE"
    assert_equal %w[none], doc["token_endpoint_auth_methods_supported"], "public clients only"
    assert_equal %w[mcp mcp_read], doc["scopes_supported"]
  end

  test "protected resource metadata names this MCP endpoint and its auth server" do
    get "/.well-known/oauth-protected-resource"
    assert_response :success
    doc = JSON.parse(response.body)

    assert_equal "http://www.example.com/mcp", doc["resource"]
    assert_equal [ "http://www.example.com" ], doc["authorization_servers"]
  end

  test "the resource-scoped metadata path resolves too" do
    get "/.well-known/oauth-protected-resource/mcp"
    assert_response :success
    assert_equal "http://www.example.com/mcp", JSON.parse(response.body)["resource"]
  end

  # --- dynamic client registration -----------------------------------------

  test "a client registers itself and gets a public client_id" do
    assert_difference -> { Doorkeeper::Application.count }, 1 do
      register_client(client_name: "Codex CLI")
    end
    assert_response :created
    doc = JSON.parse(response.body)

    assert doc["client_id"].present?
    assert_nil doc["client_secret"], "public client — no secret is issued"
    assert_equal "none", doc["token_endpoint_auth_method"]
    assert_equal "mcp mcp_read", doc["scope"]
    refute Doorkeeper::Application.find_by(uid: doc["client_id"]).confidential?
  end

  test "registration without a redirect URI is rejected" do
    assert_no_difference -> { Doorkeeper::Application.count } do
      post "/oauth/register", params: { client_name: "Broken" }, as: :json
    end
    assert_response :bad_request
    assert_equal "invalid_redirect_uri", JSON.parse(response.body)["error"]
  end

  test "registration for an unsupported scope is rejected" do
    assert_no_difference -> { Doorkeeper::Application.count } do
      register_client(scope: "mcp admin")
    end
    assert_response :bad_request
    assert_equal "invalid_scope", JSON.parse(response.body)["error"]
  end

  # --- authorize ------------------------------------------------------------

  test "authorize sends a signed-out user to sign in and returns afterwards" do
    get authorize_path(client_id: registered_client.uid)

    assert_redirected_to "/users/sign_in"
    assert_match "/oauth/authorize", session[:"passwordless_prev_location--user"],
                 "the authorize request must be resumed after the magic link"
  end

  test "a GET never authorizes — it renders consent naming the client" do
    sign_in_as @user
    get authorize_path(client_id: registered_client.uid)

    assert_response :success
    assert_select "h1", /Connect Test client/
    assert_equal 0, Doorkeeper::AccessGrant.count,
                 "registration is open, so a GET must not be able to mint a code"
  end

  test "consent carries the request forward: single org is bound, no choice offered" do
    sign_in_as @user
    get authorize_path(client_id: registered_client.uid)

    assert_select "input[name=organization_id][value=?]", @org.id.to_s
    assert_select "input[type=radio]", false, "one org needs no picker"
    assert_includes response.body, code_challenge, "PKCE must survive consent"
  end

  test "a multi-org user picks which organization the connection is bound to" do
    second = Organization.create_for(@user, name: "Second Org")
    sign_in_as @user
    get authorize_path(client_id: registered_client.uid)

    assert_response :success
    assert_select "input[type=radio][name=organization_id][value=?]", @org.id.to_s
    assert_select "input[type=radio][name=organization_id][value=?]", second.id.to_s
  end

  test "consent for an unknown client falls through to doorkeeper's error" do
    sign_in_as @user
    get authorize_path(client_id: "not-a-client")

    assert_select "h1", { count: 0, text: /Connect/ }
    assert_equal 0, Doorkeeper::AccessGrant.count
  end

  test "authorizing into an org the user does not belong to is refused" do
    sign_in_as @user
    approve(organization_id: @other_org.id)

    assert_response :forbidden
    assert_equal 0, Doorkeeper::AccessGrant.count, "no grant may be issued"
  end

  test "approving with no organization at all is refused" do
    sign_in_as @user
    approve(organization_id: nil)

    assert_response :forbidden
    assert_equal 0, Doorkeeper::AccessGrant.count
  end

  # --- token exchange -------------------------------------------------------

  test "authorize to token to MCP call: the whole connect flow" do
    raw = connect!
    token = Doorkeeper::AccessToken.by_token(raw)

    assert_equal @org.id, token.organization_id, "the token carries its org"
    assert_equal "http://www.example.com/mcp", token.resource, "audience-bound (RFC 8707)"

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :success
    assert_equal @user, McpCall.last.user, "the call runs as the authorizing user"
  end

  test "tokens are stored as digests, not in the clear" do
    raw = connect!

    refute_equal raw, Doorkeeper::AccessToken.last.token,
                 "a database read must not yield a usable bearer token"
    assert Doorkeeper::AccessToken.by_token(raw).present?, "lookup by raw token still works"
  end

  test "an mcp_read token can read but not deploy" do
    @org.apps.create!(name: "app-a", slug: "app-a")
    raw = connect!(scope: "mcp_read")

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :success

    call_tool("conductor_app", { action: "deploy", app_name: "app-a" }, bearer: raw)
    assert_response :unprocessable_entity
    assert_match(/read-only/, response.body)
  end

  test "a plain member asking for full scope is still read-only" do
    member = User.create!(email: "member@example.com")
    @org.memberships.create!(user: member, role: "member")
    @org.apps.create!(name: "app-a", slug: "app-a")
    raw = connect!(user: member)

    call_tool("conductor_app", { action: "deploy", app_name: "app-a" }, bearer: raw)
    assert_response :unprocessable_entity
    assert_match(/read-only/, response.body)
  end

  test "an OAuth token is scoped to its org and cannot see another org's app" do
    @other_org.apps.create!(name: "app-b", slug: "app-b")
    raw = connect!

    call_tool("conductor_app", { action: "deploy", app_name: "app-b" }, bearer: raw)
    assert_match(/App not found/, response.body)
  end

  test "PKCE: the code cannot be redeemed without the verifier" do
    code = authorize_for_code!
    post "/oauth/token", params: {
      grant_type: "authorization_code", code: code, client_id: registered_client.uid,
      redirect_uri: REDIRECT_URI
    }, as: :json

    assert_response :bad_request
    assert_equal 0, Doorkeeper::AccessToken.count
  end

  test "refreshing keeps the org, the audience, and the scope" do
    exchange!(authorize_for_code!)
    refresh_token = JSON.parse(response.body).fetch("refresh_token")

    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: refresh_token,
                                   client_id: registered_client.uid }, as: :json
    assert_response :success
    raw = JSON.parse(response.body).fetch("access_token")
    refreshed = Doorkeeper::AccessToken.by_token(raw)

    assert_equal @org.id, refreshed.organization_id, "the org survives a refresh"
    assert_equal "http://www.example.com/mcp", refreshed.resource, "so does the audience"
    assert_equal "mcp", refreshed.scopes.to_s

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :success
  end

  # --- what /mcp refuses ----------------------------------------------------

  test "a token minted for another resource is refused (RFC 8707)" do
    raw = connect!(resource: "https://someone-elses-server.example/mcp")

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :unauthorized
  end

  test "a token with no bound resource is refused" do
    raw = connect!(resource: nil)

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :unauthorized
  end

  test "a token stops working when its user leaves the org" do
    raw = connect!
    # An org must always keep an owner, so hand ownership over before leaving —
    # otherwise Membership's last-owner invariant (correctly) refuses.
    @org.add_member(User.create!(email: "successor@example.com"), role: :owner)
    @org.memberships.find_by(user: @user).destroy!

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :unauthorized
  end

  test "a revoked token is refused" do
    raw = connect!
    Doorkeeper::AccessToken.by_token(raw).revoke

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :unauthorized
  end

  test "the user can revoke a connection from the Tokens page" do
    raw = connect!
    application_id = Doorkeeper::AccessToken.by_token(raw).application_id

    @user.organizations.update_all(onboarded_at: Time.current) # else the UI redirects to onboarding
    get "/mcp_tokens"
    assert_select "td", /Test client/, "the connection is listed"

    delete "/oauth_connections/#{application_id}"
    assert_redirected_to mcp_tokens_path

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :unauthorized, "revoking must cut the client off immediately"
    assert_equal 0, Doorkeeper::AccessGrant.where(revoked_at: nil).count, "grants are revoked too"
  end

  test "one user cannot revoke another user's connection" do
    raw = connect!
    application_id = Doorkeeper::AccessToken.by_token(raw).application_id

    intruder = User.create!(email: "intruder@example.com")
    @org.memberships.create!(user: intruder, role: "member")
    sign_in_as intruder
    delete "/oauth_connections/#{application_id}"

    call_tool("conductor_read", { action: "fleet_status" }, bearer: raw)
    assert_response :success, "the owner's connection must survive"
  end

  test "an unauthenticated MCP call challenges with the resource metadata" do
    call_tool("conductor_read", { action: "fleet_status" }, bearer: "nonsense")

    assert_response :unauthorized
    assert_equal %(Bearer resource_metadata="http://www.example.com/.well-known/oauth-protected-resource"),
                 response.headers["WWW-Authenticate"]
  end

  private

  def register_client(client_name: "Test client", scope: nil)
    params = { client_name: client_name, redirect_uris: [ REDIRECT_URI ] }
    params[:scope] = scope if scope
    post "/oauth/register", params: params, as: :json
  end

  def registered_client
    @registered_client ||= begin
      register_client
      Doorkeeper::Application.find_by!(uid: JSON.parse(response.body)["client_id"])
    end
  end

  def code_challenge
    Base64.urlsafe_encode64(Digest::SHA256.digest(VERIFIER), padding: false)
  end

  def authorize_params(client_id:, scope: "mcp", resource: "http://www.example.com/mcp")
    params = {
      client_id: client_id, redirect_uri: REDIRECT_URI, response_type: "code",
      scope: scope, code_challenge: code_challenge, code_challenge_method: "S256"
    }
    params[:resource] = resource if resource
    params
  end

  def authorize_path(client_id:, scope: "mcp", resource: "http://www.example.com/mcp")
    "/oauth/authorize?#{authorize_params(client_id: client_id, scope: scope, resource: resource).to_query}"
  end

  # Submits the consent form — the POST the user's browser sends after approving.
  def approve(organization_id:, scope: "mcp", resource: "http://www.example.com/mcp")
    params = authorize_params(client_id: registered_client.uid, scope: scope, resource: resource)
    params[:organization_id] = organization_id if organization_id
    post "/oauth/authorize", params: params
  end

  # Signs in, approves, and returns the issued authorization code.
  def authorize_for_code!(scope: "mcp", resource: "http://www.example.com/mcp", user: nil)
    sign_in_as(user || @user)
    approve(organization_id: @org.id, scope: scope, resource: resource)
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query).fetch("code")
  end

  def exchange!(code)
    post "/oauth/token", params: {
      grant_type: "authorization_code", code: code, client_id: registered_client.uid,
      redirect_uri: REDIRECT_URI, code_verifier: VERIFIER
    }, as: :json
    assert_response :success
  end

  # The full client dance: register, consent, exchange. Returns the RAW access
  # token (the only time it exists in the clear — the row stores a digest).
  def connect!(scope: "mcp", resource: "http://www.example.com/mcp", user: nil)
    exchange!(authorize_for_code!(scope: scope, resource: resource, user: user))
    JSON.parse(response.body).fetch("access_token")
  end

  def sign_in_as(user)
    session_record = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{session_record.to_param}/#{session_record.token}"
  end

  def call_tool(name, input, bearer:)
    post "/mcp/call", params: { name: name, input: input },
         headers: { "Authorization" => "Bearer #{bearer}" }, as: :json
  end
end
