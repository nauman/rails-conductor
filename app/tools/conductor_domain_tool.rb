# Consolidated domain tool: flat `action` enum delegating via EnumDispatch.
class ConductorDomainTool
  include EnumDispatch

  ACTIONS = {
    "add"    => AddDomainTool,
    "remove" => RemoveDomainTool
  }.freeze

  DEFINITION = {
    name: "conductor_domain",
    description: "Caddy domains. Set `action` to one of: " \
      "add (route a domain to an app — server_id, domain, upstream as a unix socket path or host:port), " \
      "remove (remove a domain from Caddy — server_id, domain). " \
      "Both change live routing — confirm with the user first.",
    input_schema: {
      type: "object",
      properties: {
        action:    { type: "string", enum: %w[add remove], description: "Which domain operation" },
        server_id: { type: "integer", description: "server where Caddy runs" },
        domain:    { type: "string",  description: "domain name (e.g. myapp.com)" },
        upstream:  { type: "string",  description: "add: unix socket path (/tmp/puma-myapp.sock) or host:port (localhost:3000)" }
      },
      required: %w[action]
    }
  }.freeze
end
