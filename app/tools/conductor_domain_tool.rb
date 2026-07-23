# Consolidated domain tool: flat `action` enum delegating via EnumDispatch.
class ConductorDomainTool
  include EnumDispatch

  ACTIONS = {
    "add"                   => AddDomainTool,
    "remove"                => RemoveDomainTool,
    "put_behind_cloudflare" => PutBehindCloudflareTool
  }.freeze

  DEFINITION = {
    name: "conductor_domain",
    description: "Domains & edge routing. Set `action` to one of: " \
      "add (route a domain to an app in Caddy — server_id, domain, upstream as a unix socket path or host:port), " \
      "remove (remove a domain from Caddy — server_id, domain), " \
      "put_behind_cloudflare (proxy an app's domain through Cloudflare for CDN + edge TLS — app_id or app_name, optional ssl_mode; needs a Verified Cloudflare account, see conductor_read action=cloudflare). " \
      "All change live routing — confirm with the user first.",
    input_schema: {
      type: "object",
      properties: {
        action:    { type: "string", enum: %w[add remove put_behind_cloudflare], description: "Which domain operation" },
        server_id: { type: "integer", description: "add/remove: server where Caddy runs" },
        domain:    { type: "string",  description: "add/remove: domain name (e.g. myapp.com)" },
        upstream:  { type: "string",  description: "add: unix socket path (/tmp/puma-myapp.sock) or host:port (localhost:3000)" },
        app_id:    { type: "integer", description: "put_behind_cloudflare: the app whose domain to proxy" },
        app_name:  { type: "string",  description: "put_behind_cloudflare: the app whose domain to proxy (alt to app_id)" },
        ssl_mode:  { type: "string",  description: "put_behind_cloudflare: zone SSL mode (default 'full'; off/flexible/full/strict)" }
      },
      required: %w[action]
    }
  }.freeze
end
