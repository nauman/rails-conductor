# Consolidated domain tool: flat `action` enum delegating via EnumDispatch.
class ConductorDomainTool
  include EnumDispatch

  ACTIONS = {
    "add"                   => AddDomainTool,
    "remove"                => RemoveDomainTool,
    "put_behind_cloudflare" => PutBehindCloudflareTool,
    "purge_cloudflare"      => PurgeCloudflareTool,
    "set_dns"               => SetDnsRecordTool,
    "delete_dns"            => DeleteDnsRecordTool,
    "enable_on_demand_tls"  => EnableOnDemandTlsTool,
    "remove_stray_proxy"    => RemoveStrayProxyTool
  }.freeze

  DEFINITION = {
    name: "conductor_domain",
    description: "Domains & edge routing. Set `action` to one of: " \
      "add (route a domain to an app in Caddy — server_id, domain, upstream as a unix socket path or host:port), " \
      "remove (remove a domain from Caddy — server_id, domain), " \
      "put_behind_cloudflare (proxy an app's domain through Cloudflare for CDN + edge TLS — app_id or app_name, optional ssl_mode; needs a Verified Cloudflare account, see conductor_read action=cloudflare), " \
      "purge_cloudflare (purge an app's Cloudflare cache — app_id or app_name, optional files array of URLs; omit files to purge everything. Use after a deploy that left stale/404'd assets at the edge), " \
      "set_dns (create/update a Cloudflare DNS record via a connected account that owns the zone — domain, content, optional type (A/AAAA/CNAME/TXT, default A), proxied=false. TXT covers SPF, DKIM and domain-verification tokens; a TXT record cannot be proxied. Idempotent; zero vault), " \
      "delete_dns (delete a Cloudflare DNS record by name — domain. Idempotent; for cleaning up a subdomain that pointed at a decommissioned host), " \
      "enable_on_demand_tls (turn on Caddy on-demand TLS for a zone on a host-Caddy server so each subdomain gets its own Let's Encrypt cert on first request, gated by an app ask endpoint — server_id/server_name, domain, ask_upstream; use when Cloudflare can't proxy the wildcard), " \
      "remove_stray_proxy (remove an INERT kamal-proxy container left on a host-Caddy box after it migrated off kamal-proxy — server_id/server_name. Report-first: bare call inspects, confirm:true removes. Refuses unless the box is host-Caddy AND kamal-proxy routes/binds nothing, so it can't break a live proxy box). " \
      "All change live routing — confirm with the user first.",
    input_schema: {
      type: "object",
      properties: {
        action:    { type: "string", enum: %w[add remove put_behind_cloudflare purge_cloudflare set_dns delete_dns enable_on_demand_tls remove_stray_proxy], description: "Which domain operation" },
        confirm:   { type: "boolean", description: "remove_stray_proxy: required to remove; without it returns the inspection report only" },
        server_name:  { type: "string",  description: "enable_on_demand_tls: host-Caddy server by name (or server_id)" },
        ask_upstream: { type: "string",  description: "enable_on_demand_tls: host:port serving the ask endpoint (app loopback publish, e.g. 127.0.0.1:9080)" },
        repoint_shared_gate: { type: "boolean", description: "enable_on_demand_tls: Caddy has ONE permission endpoint per instance. Pass true only to move it deliberately (e.g. repairing a gate a previous enable overwrote) — otherwise a differing endpoint is refused, because moving it stops every other zone issuing certificates" },
        ask_path:     { type: "string",  description: "enable_on_demand_tls: ask endpoint path (default /caddy/ask)" },
        subject:      { type: "string",  description: "enable_on_demand_tls: override the on-demand subject (default *.<domain>)" },
        server_id: { type: "integer", description: "add/remove: server where Caddy runs" },
        domain:    { type: "string",  description: "add/remove/set_dns: domain / record name (e.g. myapp.com)" },
        upstream:  { type: "string",  description: "add: unix socket path (/tmp/puma-myapp.sock) or host:port (localhost:3000)" },
        app_id:    { type: "integer", description: "put_behind_cloudflare/purge_cloudflare: the target app" },
        app_name:  { type: "string",  description: "put_behind_cloudflare/purge_cloudflare: the target app (alt to app_id)" },
        ssl_mode:  { type: "string",  description: "put_behind_cloudflare: zone SSL mode (default 'full'; off/flexible/full/strict)" },
        files:     { type: "array", items: { type: "string" }, description: "purge_cloudflare: specific full URLs to purge (omit = purge everything)" },
        content:   { type: "string",  description: "set_dns: record value — an IP for A, a hostname for CNAME, or the full string for TXT" },
        type:      { type: "string",  description: "set_dns: record type (default A; A/AAAA/CNAME/TXT)" },
        proxied:   { type: "boolean", description: "set_dns: proxy through Cloudflare (orange cloud)? Default false (DNS-only)" }
      },
      required: %w[action]
    }
  }.freeze
end
