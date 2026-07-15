# Shared Bearer-token authentication for the MCP endpoints.
#
# Two token kinds (see docs/USAGE.md "MCP Server"):
#   - A per-user / per-org ApiToken runs as that user, scoped to the token's
#     organization and read/write scope (multi-tenant).
#   - The shared CONDUCTOR_MCP_TOKEN env var runs as the first admin with global
#     scope (legacy single-tenant).
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

    if (api_token = ApiToken.authenticate(token))
      org = api_token.organization
      # Revoke on membership removal: a token stays valid in the DB, but its user
      # must still belong to the org it's scoped to, or it grants nothing.
      return render_unauthorized if org && !api_token.user.organizations.exists?(id: org.id)

      @mcp_user = api_token.user
      Current.organization = org
      Current.org_scoped = org.present? # token binding confines even admins to this org
      Current.read_only = api_token.read_only?
      return
    end

    expected = ENV["CONDUCTOR_MCP_TOKEN"]
    if expected.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected)
      @mcp_user = User.admins.first
      return
    end

    render_unauthorized
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
