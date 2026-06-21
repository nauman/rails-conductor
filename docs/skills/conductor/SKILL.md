---
name: conductor
description: Use to operate a self-hosted Rails fleet through Conductor's MCP server — fleet status/logs, registering servers/clusters, creating/updating/deploying apps, provisioning databases, managing domains and env vars, wiring GitHub access. Fires on fleet/server/deploy/route/database framing when Conductor is the control plane. Real infrastructure actions on owned servers — confirm before destructive or outward-facing ones.
---

# Conductor — operating the fleet over MCP

Conductor is a Rails control plane for self-hosted ops, and part of the **InventList**
suite of self-hosting tools. This skill is the judgment layer that complements the
tool schemas at `GET /mcp/list`: when to reach for each tool, the discover-then-act
flow, and safe ordering. It is shipped with the product and served live at
`GET /mcp/skill`, so it can never drift from the tool set.

## The seven tools (flat `action` enums)

Each tool takes an `action` plus the params that action needs. Always trust
`/mcp/list` for exact schemas.

- **`conductor_read`** — `fleet_status` (servers + apps + health), `logs` (recent
  script/deploy runs), `deployment` (one deployment's status + log). Read-only.
- **`conductor_app`** — `create`, `update`, `deploy`, `sync_status`.
- **`conductor_app_config`** — `set_env`, `gen_deploy_key`.
- **`conductor_server`** — `register`, `run_script`.
- **`conductor_database`** — `register_cluster`, `provision`.
- **`conductor_domain`** — `add`, `remove`.
- **`conductor_github`** — `set_token`, `set_app`, `installations`.

## Deploy-from-chat — the happy path

Drive a deploy as this sequence, confirming before the destructive step:

1. `conductor_read` `action: fleet_status` — orient; pick the server, confirm health.
2. `conductor_app` `action: create` — only if the app is new (needs name,
   repository_url, deploy_method).
3. `conductor_app_config` `action: gen_deploy_key` — only for a private repo; add
   the returned public key to the repo (or set a token via `conductor_github`).
4. `conductor_app_config` `action: set_env` — one call per variable.
5. **Confirm with the user**, then `conductor_app` `action: deploy`.
6. `conductor_read` `action: deployment` `tail: 50` — watch until it goes green.

## Safety

- **Orient before acting** — `conductor_read action: fleet_status` first.
- **Confirm before destructive/outward-facing actions**: `conductor_app action: deploy`,
  `conductor_domain action: remove`, `conductor_database action: provision`.
- A read-only token may call only `conductor_read`; everything else needs a
  deploy-scoped token.

When driving a specific instance, fetch `/mcp/skill` from it for the
version-matched copy rather than relying on a cached version.
