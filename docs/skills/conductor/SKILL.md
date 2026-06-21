---
name: conductor
description: Use to operate a self-hosted Rails fleet through Conductor's MCP server — fleet status/logs, registering servers/clusters, creating/updating/deploying apps, provisioning databases, managing domains and env vars, wiring GitHub access. Fires on fleet/server/deploy/route/database framing when Conductor is the control plane. Real infrastructure actions on owned servers — confirm before destructive or outward-facing ones.
---

# Conductor (fleet via MCP)

Endpoint `/mcp` — `GET /mcp/list` to discover, `POST /mcp/call` to invoke, `GET /mcp/skill` for this doc. Auth: Bearer `CONDUCTOR_MCP_TOKEN` (or a per-user/org API token; `401` if neither). Tool defs come from `ToolRegistry` (`app/tools/tool_registry.rb`) — always trust `/mcp/list` over this doc.

## Surface: 7 flat tools, each with an `action`

The surface is **seven flat tools**; each call sets `action` plus that action's params (fewer tools keeps agent tool-selection accurate). Call shape: `{"name":"conductor_read","input":{"action":"fleet_status"}}`.

| Tool | Actions | Notes |
|------|---------|-------|
| `conductor_read` | `fleet_status`, `logs`, `deployment` | Read-only. Orient here first. |
| `conductor_app` | `create`, `update`, `deploy`, `sync_status` | Mutating — confirm. `deploy` dispatches by deploy_method. |
| `conductor_app_config` | `set_env`, `gen_deploy_key` | `gen_deploy_key` returns the PUBLIC key to add on GitHub. |
| `conductor_server` | `register`, `run_script` | `run_script` creates a ScriptRun + enqueues. |
| `conductor_database` | `register_cluster`, `provision` | `provision` returns a connection URL — confirm. |
| `conductor_domain` | `add`, `remove` | `remove` is destructive — confirm. |
| `conductor_github` | `set_token`, `set_app`, `installations` | Stores credentials Conductor-wide. |

## Flow
1. `conductor_read action: fleet_status` to orient → `action: logs` / `action: deployment` to diagnose.
2. Mutating app config, deploying, provisioning DBs, changing domains, or storing GitHub credentials are real infra actions on owned servers — **confirm with the user before each**, especially `conductor_domain action: remove`, `conductor_database action: provision`, and the `conductor_github` actions.
3. After `conductor_app action: deploy`, poll `conductor_read action: deployment` (pass `deployment_id`, or `app_id`/`app_name` for the latest) to confirm success.

Setup: the Conductor MCP server must be connected in the session (see `docs/USAGE.md` "MCP Server"). Authoring new tools? Follow the `mcp-authoring` skill — thin flat enum tools + this fat skill.
