# Revoking an OAuth connection (spec 06). A "connection" is one client
# (Doorkeeper::Application) authorized by the current user for the active org;
# revoking kills its access tokens — which carry the refresh tokens — and any
# unredeemed grants, so the client cannot refresh its way back in.
#
# Without this, a lost or misbehaving client could only be cut off by the client
# itself calling /oauth/revoke, or by an operator editing the database.
class OauthConnectionsController < ApplicationController
  def destroy
    connection_tokens.each(&:revoke)
    connection_grants.each(&:revoke)

    redirect_to mcp_tokens_path, notice: "Connection revoked."
  end

  private

  # Scoped to the current user AND org: revoking is not a cross-tenant action,
  # and one user must not be able to revoke another's connection.
  def connection_tokens
    Doorkeeper::AccessToken.where(resource_owner_id: current_user.id,
                                  application_id: params[:id],
                                  organization_id: current_organization.id,
                                  revoked_at: nil)
  end

  def connection_grants
    Doorkeeper::AccessGrant.where(resource_owner_id: current_user.id,
                                  application_id: params[:id],
                                  organization_id: current_organization.id,
                                  revoked_at: nil)
  end
end
