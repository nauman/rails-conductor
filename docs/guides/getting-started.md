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
6. **[Deploy](deploy-an-app).** From the UI, the CLI, or an agent.
7. **Point a domain.** Conductor manages routing + TLS (Let's Encrypt) via the shared proxy.

## Topologies

Conductor doesn't force one layout:

- **Standalone** — one app on its own box.
- **Fleet** — many apps on one shared box (shared proxy + shared Postgres), for density.

Deploy method and topology are independent choices.

## Drive it three ways

- **Web UI** — the dashboard at `/dashboard`.
- **CLI** — scripted operations.
- **MCP** — AI agents call Conductor's tools (e.g. `register_server`, `provision_database`, `create_app`, `deploy_app`) to run the whole loop programmatically.

Next: **[Deploy an app](deploy-an-app)**.
