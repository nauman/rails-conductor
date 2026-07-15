class Current < ActiveSupport::CurrentAttributes
  # org_scoped: set true ONLY when the request authenticated via an org-bound API
  # token (multi-tenant MCP). The web UI also sets `organization` (the actor's
  # current org), but that must NOT strip an admin's global scope — only a
  # token binding does. Distinguishes token-scoping from web-session context.
  attribute :user, :organization, :read_only, :org_scoped
end
