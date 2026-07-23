---
title: Getting started
description: What Conductor is, and the path from a fresh server to a deployed app.
order: 1
---

# Getting started

Conductor is the **control plane for self-hosted Rails ops across a fleet** — it manages servers, apps, routing, databases, backups, and provider APIs, across **Kamal, native, and Docker** deploys, driven by a web UI, a CLI, and **AI agents over MCP**.

## The core loop

```
Register a server  →  Add an app  →  Connect GitHub  →  Deploy  →  Point a domain
```

1. **Register a server.** Add a host Conductor can reach over SSH (provide its IP + an SSH key). One server can host many apps.
2. **Provision a database** (optional). Register a Postgres cluster and provision a per-app database + role; Conductor surfaces the `DATABASE_URL`.
3. **Add an app.** Give it a name, repository URL, server, and a **deploy method** — `kamal`, `native`, or `docker`.
4. **[Connect GitHub](connect-github).** So Conductor can clone private repos.
5. **Set env vars.** `SECRET_KEY_BASE`, `DATABASE_URL`, API keys — managed per app in Conductor.
6. **[Deploy](deploy-an-app).** From the UI or an agent (an MCP endpoint any agent can drive).
7. **Point a domain.** Conductor manages routing + TLS (Let's Encrypt) via the shared proxy.

## Topologies

Conductor doesn't force one layout:

- **Standalone** — one app on its own box.
- **Fleet** — many apps on one shared box (shared proxy + shared Postgres), for density.

Deploy method and topology are independent choices.

## Drive it two ways (CLI in progress)

- **Web UI** — the dashboard at `/dashboard`.
- **MCP** — the full toolset over HTTP: AI agents (or your own scripts via `curl`) call Conductor's tools to run the whole loop programmatically. See [Deploy via MCP](mcp).
- **CLI** *(early / in progress)* — `bin/conductor` currently covers secret-safe `set-env` and a generic `call <tool>` passthrough over the MCP endpoint. A fuller command set is planned; until then, script against MCP directly.

Next: **[Deploy an app](deploy-an-app)**.
