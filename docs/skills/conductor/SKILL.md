---
name: conductor
description: Use to operate a self-hosted Rails fleet through Conductor's MCP server — fleet status/logs, registering servers/clusters, creating/updating/deploying apps, provisioning databases, managing domains and env vars, wiring GitHub access. Fires on fleet/server/deploy/route/database framing when Conductor is the control plane. Real infrastructure actions on owned servers — confirm before destructive or outward-facing ones.
---

# Conductor (fleet via MCP)

Endpoint `/mcp` — `GET /mcp/list` to discover, `POST /mcp/call` to invoke, `GET /mcp/skill` for this doc. Auth: Bearer `CONDUCTOR_MCP_TOKEN` (or a per-user/org API token; `401` if neither). Tool defs come from `ToolRegistry` (`app/tools/tool_registry.rb`) — always trust `/mcp/list` over this doc.

## Surface: 10 flat tools, each with an `action`

The surface is **ten flat tools**; each call sets `action` plus that action's params (fewer tools keeps agent tool-selection accurate). Call shape: `{"name":"conductor_read","input":{"action":"fleet_status"}}`.

| Tool | Actions | Notes |
|------|---------|-------|
| `conductor_read` | `fleet_status`, `logs`, `deployment` | Read-only. Orient here first. `deployment` returns the app's deploy runbook + checklist. |
| `conductor_app` | `create`, `update`, `deploy`, `rollback`, `sync_status`, `cancel`, `convert_database`, `transfer_plan`, `transfer`, `runner` | Mutating — confirm. `deploy` dispatches by deploy_method. `runner` runs a one-off Rails command in the app's LIVE container over SSH (non-interactive `kamal console`): `ruby` (arbitrary Ruby via `rails runner`) **or** `task` (a bare rails/rake task like `db:migrate:status`); kamal + docker apps only. A mutating `ruby`/`task` runs real code against production — **confirm before anything that writes.** For an interactive REPL, use `kamal console` from the repo instead. |
| `conductor_app_config` | `set_env`, `gen_deploy_key`, `install_webhook` | `gen_deploy_key` returns the PUBLIC key to add on GitHub. `install_webhook` wires push-to-deploy in one call — installs a GitHub push webhook (pointing at Conductor, HMAC-signed with the app's secret) + enables `auto_deploy`; needs an org GitHub token (`conductor_github action: set_token`). |
| `conductor_server` | `register`, `update`, `add_ssh_key`, `test_connection`, `audit`, `apply_updates`, `install_packages`, `run_script`, `remove` | `add_ssh_key` generates a deploy key (returns public key); `update` attaches a key / sets login user; `test_connection` verifies SSH + refreshes metrics; `run_script` enqueues a ScriptRun; `remove` deregisters a server (refuses if apps attached unless `force`) — destructive, confirm. |
| `conductor_database` | `register_cluster`, `provision` | `provision` returns a connection URL — confirm. |
| `conductor_domain` | `add`, `remove`, `put_behind_cloudflare`, `purge_cloudflare`, `set_dns` | `remove` is destructive — confirm. `put_behind_cloudflare` proxies a domain (CDN + edge TLS); `purge_cloudflare` clears the edge cache (optional `files` URLs, else everything) after a deploy that left stale/404'd assets; `set_dns` creates/updates an A/CNAME record (idempotent; `proxied=false` = DNS-only) via the connected account that owns the zone — zero vault; `delete_dns` removes a record by name (idempotent — for cleaning up a subdomain that pointed at a decommissioned host). All need a Verified Cloudflare account (see `conductor_read action: cloudflare`). |
| `conductor_github` | `set_token`, `set_app`, `installations` | Stores credentials Conductor-wide. |
| `conductor_runbook` | `get`, `set_runbook`, `add_item`, `remove_item`, `check_item`, `reset` | Per-app deploy runbook + checklist. **Read (`get`) before deploying** — each app deploys differently. Work the checklist during deploy; `reset` before a new one. |
| `conductor_cron` | `schedule`, `list`, `remove`, `set_enabled` | Scheduled jobs (Heroku-Scheduler equivalent) — installs managed crontab entries. `schedule` an app rails task (`app_id` + `task` like `slack:sync` + `schedule` '`every hour`'/'`0 * * * *`') to run in the app's container, or a raw `command` on a `server_id`. |
| `conductor_storage` | `audit`, `configure`, `migrate` | App Active Storage / R2. `audit` = where blobs live + configured service + reachability + count not on it (read-only). `configure` = generate the R2 storage.yml + production.rb + env keys to add (no secrets). `migrate` = upload blobs local→cloudflare_r2 and repoint them; chunked via `limit`, idempotent (mutating). audit/migrate exec `bin/rails runner` in the app container over SSH. Use after a host migration that left images 404'ing (files not carried with the DB). |

## Flow
1. `conductor_read action: fleet_status` to orient → `action: logs` / `action: deployment` to diagnose.
2. Mutating app config, deploying, provisioning DBs, changing domains, or storing GitHub credentials are real infra actions on owned servers — **confirm with the user before each**, especially `conductor_domain action: remove`, `conductor_database action: provision`, and the `conductor_github` actions.
3. **Before deploying an app**, `conductor_runbook action: get` (or read the runbook + checklist from `conductor_read action: deployment`) — each app deploys differently. Work the checklist as you go (`check_item`), and `reset` it before a fresh deploy.
4. After `conductor_app action: deploy`, poll `conductor_read action: deployment` (pass `deployment_id`, or `app_id`/`app_name` for the latest) to confirm success.

Setup: the Conductor MCP server must be connected in the session (see `docs/USAGE.md` "MCP Server"). Authoring new tools? Follow the `mcp-authoring` skill — thin flat enum tools + this fat skill.
