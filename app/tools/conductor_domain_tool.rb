# Consolidated domain tool: flat `action` enum delegating via EnumDispatch.
class ConductorDomainTool
  include EnumDispatch

  ACTIONS = {
    "add"                   => AddDomainTool,
    "remove"                => RemoveDomainTool,
    "put_behind_cloudflare" => PutBehindCloudflareTool,
    "purge_cloudflare"      => PurgeCloudflareTool,
    "set_dns"               => SetDnsRecordTool,
    "delete_dns"            => DeleteDnsRecordTool
  }.freeze

  DEFINITION = {
    name: "conductor_domain",
    description: "Domains & edge routing. Set `action` to one of: " \
      "add (route a domain to an app in Caddy — server_id, domain, upstream as a unix socket path or host:port), " \
      "remove (remove a domain from Caddy — server_id, domain), " \
      "put_behind_cloudflare (proxy an app's domain through Cloudflare for CDN + edge TLS — app_id or app_name, optional ssl_mode; needs a Verified Cloudflare account, see conductor_read action=cloudflare), " \
      "purge_cloudflare (purge an app's Cloudflare cache — app_id or app_name, optional files array of URLs; omit files to purge everything. Use after a deploy that left stale/404'd assets at the edge), " \
      "set_dns (create/update a Cloudflare A/CNAME record via a connected account that owns the zone — domain, content, optional type=A, proxied=false. Idempotent; zero vault), " \
      "delete_dns (delete a Cloudflare DNS record by name — domain. Idempotent; for cleaning up a subdomain that pointed at a decommissioned host). " \
      "All change live routing — confirm with the user first.",
    input_schema: {
      type: "object",
      properties: {
        action:    { type: "string", enum: %w[add remove put_behind_cloudflare purge_cloudflare set_dns delete_dns], description: "Which domain operation" },
        server_id: { type: "integer", description: "add/remove: server where Caddy runs" },
        domain:    { type: "string",  description: "add/remove/set_dns: domain / record name (e.g. myapp.com)" },
        upstream:  { type: "string",  description: "add: unix socket path (/tmp/puma-myapp.sock) or host:port (localhost:3000)" },
        app_id:    { type: "integer", description: "put_behind_cloudflare/purge_cloudflare: the target app" },
        app_name:  { type: "string",  description: "put_behind_cloudflare/purge_cloudflare: the target app (alt to app_id)" },
        ssl_mode:  { type: "string",  description: "put_behind_cloudflare: zone SSL mode (default 'full'; off/flexible/full/strict)" },
        files:     { type: "array", items: { type: "string" }, description: "purge_cloudflare: specific full URLs to purge (omit = purge everything)" },
        content:   { type: "string",  description: "set_dns: record target — an IP for type=A, a hostname for type=CNAME" },
        type:      { type: "string",  description: "set_dns: record type (default A; A/CNAME)" },
        proxied:   { type: "boolean", description: "set_dns: proxy through Cloudflare (orange cloud)? Default false (DNS-only)" }
      },
      required: %w[action]
    }
  }.freeze
end
