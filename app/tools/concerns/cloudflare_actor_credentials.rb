# The Cloudflare credentials an MCP actor may use: every connected account for
# the legacy admin token, else the acting user's org(s). Shared by the DNS tools
# (set_dns / delete_dns). Include alongside ActorScoped (uses actor_admin? +
# actor_org_ids).
module CloudflareActorCredentials
  def actor_cloudflare_credentials
    scope = Credential.where(provider: "cloudflare")
    actor_admin? ? scope : scope.where(organization_id: actor_org_ids)
  end
end
