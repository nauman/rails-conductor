# Self-serve issuance of per-user, org-scoped MCP/API tokens. A member mints a
# token bound to the active org; agents (Claude Desktop, Cursor) use it as the
# MCP bearer. The raw token is shown once on create and never retrievable again.
class McpTokensController < ApplicationController
  def index
    @tokens = current_organization_tokens.order(created_at: :desc)
    @new_token = flash[:new_token] # raw value shown once after create
    @connections = oauth_connections
    @can_deploy = OperatorPolicy.operator?(current_user, current_organization)
    @role = current_organization.role_for(current_user)
  end

  def create
    requested = ApiToken::SCOPES.include?(params[:scope]) ? params[:scope] : "deploy"
    # A non-operator can only mint read tokens — a deploy token would be useless
    # anyway (the tool layer rejects their mutations). The form no longer offers
    # the option, but keep the coercion as defence-in-depth for direct POSTs, and
    # say so rather than silently downgrading.
    scope = OperatorPolicy.operator?(current_user, current_organization) ? requested : "read"
    downgraded = scope != requested

    name = params[:name].presence || "agent-token"
    raw, = ApiToken.generate(user: current_user, name: name,
                             organization: current_organization, scope: scope)

    notice = "Token created — copy it now, it won't be shown again."
    notice += " Scope was set to read-only: deploying over MCP needs the editor role, so ask an owner of #{current_organization.name}." if downgraded

    redirect_to mcp_tokens_path, flash: { new_token: raw, notice: notice }
  end

  def destroy
    token = current_organization_tokens.find(params[:id])
    token.destroy
    redirect_to mcp_tokens_path, notice: "Token revoked."
  end

  private

  def current_organization_tokens
    ApiToken.where(user: current_user, organization: current_organization)
  end

  # Clients this user connected through browser sign-in (spec 06), one row per
  # client: several live access tokens for the same client are one connection.
  def oauth_connections
    return [] unless defined?(Doorkeeper)

    Doorkeeper::AccessToken
      .where(resource_owner_id: current_user.id, organization_id: current_organization.id, revoked_at: nil)
      .includes(:application)
      .order(created_at: :desc)
      .reject { |token| token.expired? && token.refresh_token.blank? }
      .uniq(&:application_id)
  end
end
