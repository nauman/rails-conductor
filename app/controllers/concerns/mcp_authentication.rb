# Shared Bearer-token authentication for the MCP endpoints.
#
# Three token kinds, tried in order (see docs/USAGE.md "MCP Server"):
#   - An OAuth access token minted through the browser connect flow (spec 06):
#     org-bound, audience-bound (RFC 8707), scope mcp / mcp_read.
#   - A per-user / per-org ApiToken runs as that user, scoped to the token's
#     organization and read/write scope (multi-tenant).
#   - The shared CONDUCTOR_MCP_TOKEN env var runs as the first admin with global
#     scope (legacy single-tenant).
#
# Whichever kind authenticates, it lands on the same request state: @mcp_user plus
# Current.organization / org_scoped / read_only. Tools scope off that and cannot
# tell the kinds apart.
#
# Included by both the custom REST controller (Mcp::ServerController) and the
# standard JSON-RPC transport (Mcp::RpcController) so the auth logic lives once.
module McpAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_mcp_token!
  end

  private

  def authenticate_mcp_token!
    token = request.headers["Authorization"]&.sub(/\ABearer\s+/, "")

    return if authenticate_oauth_token(token)
    return if authenticate_api_token(token)
    return if authenticate_shared_token(token)

    unauthorized_challenge!
    render_unauthorized
  end

  # An OAuth access token from the connect flow (spec 06). Refused unless it was
  # minted for THIS resource and carries an org its user still belongs to.
  def authenticate_oauth_token(token)
    return false unless token.present? && defined?(Doorkeeper)

    access_token = Doorkeeper::AccessToken.by_token(token)
    return false unless access_token&.accessible?
    return false unless audience_bound?(access_token)

    user = User.find_by(id: access_token.resource_owner_id)
    org = user && Organization.find_by(id: access_token.organization_id)
    # An org-less OAuth token would be an unscoped writer — the same combination
    # ApiToken forbids at the model level. Refuse it rather than widen scope.
    return false if org.nil?
    return false unless user.organizations.exists?(id: org.id)
    # A token carrying neither MCP scope grants nothing — don't let an unrecognised
    # scope string fall through as full access.
    return false unless access_token.scopes.include?("mcp") || access_token.scopes.include?("mcp_read")

    @mcp_user = user
    Current.organization = org
    Current.org_scoped = true
    # Fail closed: write access needs BOTH the `mcp` scope and a user who may
    # actually perform privileged operations in this org. McpTokensController
    # applies the same rule when issuing an ApiToken, so a member can't get a
    # more privileged request state through OAuth than through the token page.
    Current.read_only = !access_token.scopes.include?("mcp") || !OperatorPolicy.operator?(user, org)
    true
  end

  def authenticate_api_token(token)
    api_token = ApiToken.authenticate(token)
    return false unless api_token

    org = api_token.organization
    # Revoke on membership removal: a token stays valid in the DB, but its user
    # must still belong to the org it's scoped to, or it grants nothing.
    return false if org && !api_token.user.organizations.exists?(id: org.id)

    @mcp_user = api_token.user
    Current.organization = org
    Current.org_scoped = org.present? # token binding confines even admins to this org
    Current.read_only = api_token.read_only?
    true
  end

  def authenticate_shared_token(token)
    expected = ENV["CONDUCTOR_MCP_TOKEN"]
    return false unless expected.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected)

    @mcp_user = User.admins.first
    true
  end

  # RFC 8707: accept a token only if it was issued for this MCP resource, so one
  # minted for a different resource can't be replayed here (confused deputy). We
  # tolerate both the advertised resource identifier and the bare origin.
  def audience_bound?(access_token)
    bound = (access_token.respond_to?(:resource) ? access_token.resource : nil).to_s
    return false if bound.blank?

    acceptable_resources.include?(canonicalize(bound))
  end

  def acceptable_resources
    [ canonicalize(request.base_url), canonicalize("#{request.base_url}/mcp") ]
  end

  def canonicalize(uri) = uri.to_s.strip.chomp("/")

  # RFC 9728: point an unauthenticated client at the metadata describing how to
  # get a token. This header is what turns a 401 into a "Connect" prompt in an
  # MCP client instead of a dead end.
  def unauthorized_challenge!
    metadata = "#{request.base_url}/.well-known/oauth-protected-resource"
    response.set_header("WWW-Authenticate", %(Bearer resource_metadata="#{metadata}"))
  end

  # Overridden by the JSON-RPC controller to return a protocol-shaped error.
  def render_unauthorized
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  # The actor for this MCP call — a per-user token's user, or the first admin
  # for the legacy shared token. Tools scope resource access off this user.
  def mcp_user
    @mcp_user
  end
end
