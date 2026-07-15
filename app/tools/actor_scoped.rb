# Scopes resource lookups to the acting user's organizations. Multi-tenant MCP:
# a per-user/per-org token (ApiToken) runs as that user — a non-admin — so its
# tools can only see and act on apps in organizations the user belongs to.
# Admins (the legacy shared CONDUCTOR_MCP_TOKEN runs as the first admin) keep
# global access, preserving existing single-tenant behaviour.
module ActorScoped
  # Global (all-org) scope is ONLY for the legacy shared token — an admin actor
  # with no bound organization (Current.organization is nil), or a nil actor
  # (trusted internal call). A per-user/per-org API token binds Current.organization,
  # so even an admin using an org-scoped token stays confined to that org — admin
  # status must not let an org-A token reach org-B resources.
  def actor_admin?
    return true if @user.nil?
    @user.admin? && !Current.org_scoped
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

  # Find a server by id/name, scoped to what the actor may touch.
  def find_server(input)
    if input["server_id"].present?
      visible_servers.find_by(id: input["server_id"])
    elsif input["server_name"].present?
      visible_servers.find_by(name: input["server_name"])
    end
  end

  # SSH keys the actor may attach to a server (admins: all; else the actor's orgs).
  def visible_ssh_keys
    actor_admin? ? SshKey.all : SshKey.where(organization_id: actor_org_ids)
  end

  private

  # When a token is bound to a specific org (Current.organization), scope to it
  # alone; otherwise fall back to all of the user's orgs.
  def actor_org_ids
    return [ Current.organization.id ] if Current.organization
    @user ? @user.organizations.ids : []
  end
end
