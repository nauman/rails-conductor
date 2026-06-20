---
title: Deploy via MCP (for AI agents)
description: Connect an AI agent to Conductor's MCP server and deploy, configure, and inspect your fleet over the Model Context Protocol — the same tools the UI uses.
order: 6
---

# Deploy via MCP

Conductor ships a built-in **MCP (Model Context Protocol) server**, so any MCP-capable agent — Claude, Cursor, your own scripts — can drive the whole fleet: register servers, create and configure apps, load env, provision databases, and **deploy** — the same operations the web UI performs, exposed as tools.

> If you can do it on an app's page, you can do it from an agent.

## Endpoint & auth

The server is mounted on your Conductor instance:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/mcp/list` | List every tool + its input schema (discovery). |
| `POST` | `/mcp/call` | Call one tool: `{ "name": "...", "input": { ... } }`. |

Authentication is a **bearer token** — the `CONDUCTOR_MCP_TOKEN` env var set on your instance:

```
Authorization: Bearer <CONDUCTOR_MCP_TOKEN>
```

Keep the token secret. Every call is recorded to the MCP **audit log** (`/admin` → MCP calls), with secret arguments redacted.

## Quick check

```bash
# List available tools
curl -s https://<your-conductor-host>/mcp/list \
  -H "Authorization: Bearer $CONDUCTOR_MCP_TOKEN" | jq '.tools[].name'

# Fleet snapshot
curl -s https://<your-conductor-host>/mcp/call \
  -H "Authorization: Bearer $CONDUCTOR_MCP_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"fleet_status","input":{}}'
```

## Connect an agent (Claude / Cursor)

Point your MCP client at the HTTP endpoint with the bearer header. For Claude Code:

```bash
claude mcp add --transport http conductor https://<your-conductor-host>/mcp \
  --header "Authorization: Bearer $CONDUCTOR_MCP_TOKEN"
```

The agent then sees `deploy_app`, `deployment_log`, and the rest as native tools.

## The toolset

**Deploy & inspect** — `deploy_app`, `deployment_log`, `sync_app_status`, `recent_logs`, `fleet_status`, `run_script`
**App lifecycle** — `create_app`, `update_app`, `set_env_variable`, `add_domain`, `remove_domain`
**Infra** — `register_server`, `register_database_cluster`, `provision_database`
**Git auth (private repos)** — `set_github_app`, `github_installations`, `set_github_token`, `generate_deploy_key`

Call `GET /mcp/list` for each tool's exact input schema.

## Worked example — deploy an app

```bash
H=https://<your-conductor-host>/mcp/call
A=(-H "Authorization: Bearer $CONDUCTOR_MCP_TOKEN" -H "Content-Type: application/json")

# 1. Point the app at its repo (kamal build over SSH, public or private repo)
curl -s "$H" "${A[@]}" -d '{"name":"update_app","input":{
  "app_name":"My App","deploy_method":"kamal",
  "repository_url":"https://github.com/acme/my-app.git","branch":"main"}}'

# 2. (Private repo) mint a deploy key, then add it to the repo:
#    gh repo deploy-key add <public_key> --repo acme/my-app --title conductor
curl -s "$H" "${A[@]}" -d '{"name":"generate_deploy_key","input":{"app_name":"My App"}}'

# 3. Load the app's env (RAILS_MASTER_KEY, DB password, …); secrets are redacted in logs
curl -s "$H" "${A[@]}" -d '{"name":"set_env_variable","input":{
  "app_name":"My App","key":"RAILS_MASTER_KEY","value":"…","secret":true}}'

# 4. Deploy — returns a deployment_id
curl -s "$H" "${A[@]}" -d '{"name":"deploy_app","input":{"app_name":"My App"}}'

# 5. Stream the result
curl -s "$H" "${A[@]}" -d '{"name":"deployment_log","input":{"deployment_id":42}}'
```

Conductor's container clones the repo, generates `.kamal/secrets` from the env you loaded, **builds on the target's Docker daemon over SSH**, and deploys behind the shared proxy. See [Deploy an app](deploy-an-app) and [Connect GitHub](connect-github).

## Security & scope

- **One shared token, admin scope.** Today every MCP call runs as the instance's first admin user. The token is all-or-nothing — treat it like a root credential, rotate it by changing `CONDUCTOR_MCP_TOKEN` and redeploying.
- **Audit log.** Every call (tool, args, affected org, duration) is recorded; secret values are redacted.
- **Roadmap.** Per-user / per-org MCP tokens scoped to an org's own apps (so any member can deploy *their* apps, not the whole fleet) is on the roadmap — see the delivery sequence, slot 14 *Multi-tenant MCP*.
