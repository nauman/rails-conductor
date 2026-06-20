# Self-serve issuance of per-user, org-scoped MCP/API tokens. A member mints a
# token bound to the active org; agents (Claude Desktop, Cursor) use it as the
# MCP bearer. The raw token is shown once on create and never retrievable again.
class McpTokensController < ApplicationController
  def index
    @tokens = current_organization_tokens.order(created_at: :desc)
    @new_token = flash[:new_token] # raw value shown once after create
  end

  def create
    scope = ApiToken::SCOPES.include?(params[:scope]) ? params[:scope] : "deploy"
    name = params[:name].presence || "agent-token"
    raw, = ApiToken.generate(user: current_user, name: name,
                             organization: current_organization, scope: scope)
    redirect_to mcp_tokens_path, flash: { new_token: raw,
      notice: "Token created — copy it now, it won't be shown again." }
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
end
