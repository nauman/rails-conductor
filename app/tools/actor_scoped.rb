# Scopes resource lookups to the acting user's organizations. Multi-tenant MCP:
# a per-user/per-org token (ApiToken) runs as that user — a non-admin — so its
# tools can only see and act on apps in organizations the user belongs to.
# Admins (the legacy shared CONDUCTOR_MCP_TOKEN runs as the first admin) keep
# global access, preserving existing single-tenant behaviour.
module ActorScoped
  # Global scope for admins and for a nil actor (a trusted internal/system call;
  # the MCP server never passes nil — auth always resolves a real user first).
  def actor_admin?
    @user.nil? || @user.admin?
  end

  # Servers this actor may touch.
  def visible_servers
    actor_admin? ? Server.all : Server.where(organization_id: actor_org_ids)
  end

  # Apps this actor may touch.
  def visible_apps
    actor_admin? ? App.all : App.where(organization_id: actor_org_ids)
  end

  # Deployments for apps this actor may touch.
  def visible_deployments
    actor_admin? ? Deployment.all : Deployment.where(app_id: visible_apps.select(:id))
  end

  # Find an app by id/name, scoped to what the actor may touch.
  def find_app(input)
    if input["app_id"].present?
      visible_apps.find_by(id: input["app_id"])
    elsif input["app_name"].present?
      visible_apps.find_by(name: input["app_name"])
    end
  end

  private

  # When a token is bound to a specific org (Current.organization), scope to it
  # alone; otherwise fall back to all of the user's orgs.
  def actor_org_ids
    return [Current.organization.id] if Current.organization
    @user ? @user.organizations.ids : []
  end
end
