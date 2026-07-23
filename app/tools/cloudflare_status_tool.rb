# Discovery for the Cloudflare integration: which accounts are connected, whether
# they're verified, which zones/domains they own, the ready-to-attach read-only MCP
# servers, and how to actually put a domain behind Cloudflare. Read-only — this is
# how a fresh agent discovers the integration exists and how to use it.
class CloudflareStatusTool
  include ActorScoped

  DEFINITION = {
    name: "cloudflare_status",
    description: "Discover the Cloudflare integration: connected accounts, owned zones, read-only MCP attach commands, and how to proxy a domain.",
    input_schema: { type: "object", properties: {}, required: [] }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(_input = {})
    creds = cloudflare_credentials
    accounts = creds.map do |c|
      {
        name: c.name,
        verified: c.verified?,
        account_id: c.account_id,
        zones: c.zones_list.map { |z| z["name"] }.compact,
        read_only_mcp_attach: c.cloudflare_mcp_commands
      }
    end

    # Apps whose domain is owned by a connected zone → ready for put_behind_cloudflare.
    proxyable = visible_apps.where.not(domain: [ nil, "" ]).filter_map do |app|
      owner = creds.find { |c| c.zones_list.any? { |z| app.domain == z["name"] || app.domain.to_s.end_with?(".#{z['name']}") } }
      { app: app.name, domain: app.domain, account: owner.name } if owner
    end

    Result.ok({
      connected_accounts: accounts,
      proxyable_apps: proxyable,
      how_to_proxy: "conductor_domain action=put_behind_cloudflare (app_id or app_name, optional ssl_mode; default full).",
      mutations_note: "All Cloudflare config changes go through Conductor's audited actions. The attached MCP servers are read-only (docs/analytics/observability) — they cannot mutate config.",
      guide: "/docs/cloudflare-mcp"
    })
  end

  private

  def cloudflare_credentials
    scope = actor_admin? ? Organization.all : Organization.where(id: actor_org_ids)
    Credential.where(organization_id: scope.select(:id), provider: "cloudflare").to_a
  end
end
