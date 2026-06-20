---
name: conductor
description: Use to operate a self-hosted Rails fleet through Conductor's MCP server — fleet status/logs, registering servers/clusters, creating/updating/deploying apps, provisioning databases, managing domains and env vars, wiring GitHub access. Fires on fleet/server/deploy/route/database framing when Conductor is the control plane. Real infrastructure actions on owned servers — confirm before destructive or outward-facing ones.
---

# Conductor skill — pointer, not the home

The canonical skill is **shipped in the product**, so it can't drift from the tools
and every Conductor user benefits (not just this agent):

- **Source of truth (versioned with `ToolRegistry`):** `docs/skills/conductor/SKILL.md`.
- **Live, version-matched to a running instance:**
  - `GET /mcp/list` — current tool names + input schemas.
  - `GET /mcp/skill` — the judgment layer (orient with fleet_status first, confirm
    before remove_domain/provision_database, poll deployment_log after deploy_app).

When driving a specific Conductor instance, fetch `/mcp/skill` from it (or read
`docs/skills/conductor/SKILL.md`) rather than relying on this stub.
