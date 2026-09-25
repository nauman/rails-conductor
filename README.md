# Conductor

**A control plane for self-hosted Rails operations.** One place to run, monitor, and maintain your apps across mixed infrastructure — whether they run with Kamal and Docker or natively with Caddy and Puma.

Conductor isn't a hosting platform and it doesn't lock you into one deployment style. It connects to servers you already own over SSH, and turns Caddy, Postgres, backups, and provider APIs into one coherent operational layer.

> **Status:** early and honest. The fleet dashboard, SSH execution, Docker deploys, backups, alerts, recurring jobs, and a baseline Caddy client work today. Routing, provider automation, restore, and drift detection are in progress. See [`documents/PILLARS.md`](documents/PILLARS.md) for the real maturity of each area.

---

## Why

If you run a handful of apps across a few VPSs, you've probably SSH'd into each box one too many times and built `/admin/server` panels inside every app just to see what's happening. Conductor is the single pane of glass instead:

- **See the whole fleet in seconds** — health, last deploy, current issues across every server and app.
- **Deploy your way** — Docker/Kamal *and* native Puma/systemd under one control plane.
- **Take action, not just observe** — deploy, restart, run scripts, manage routes, and back up databases from the UI, the API, or an AI agent over MCP.
- **Own your infrastructure** — your servers, your providers, no per-server platform fees.

## Features

- Server and app management with encrypted SSH key & credential storage
- Agentless SSH command execution with **live streaming output**
- Provisioning scripts (`server-provision`, `ruby-install`, `app-setup`, `app-deploy`, `systemd-setup`)
- Docker deployment pipeline over SSH
- Server metrics and managed container status sync, logs, and restart
- Database backups to S3/R2-compatible storage, on a schedule
- Dashboard issue detection and fleet summary
- SSH-backed Caddy route management (add/remove domains)
- Recurring ops baseline (metrics refresh, container sync, scheduled backups)
- JSON API and an **MCP server** for AI agents

## Quick Start

Requires Ruby (see `.ruby-version`). Rails 8 with Turbo, Importmaps, Tailwind, and Solid Queue.

```bash
git clone https://github.com/nauman/rails-conductor.git
cd rails-conductor
bin/setup     # install gems, prepare the database
bin/dev       # boot web + assets + jobs
```

Open http://localhost:3000 and sign in with a magic link (in development, mail is captured at `/letter_opener`).

Run the tests:

```bash
bin/rails test
```

See [`documents/USAGE.md`](documents/USAGE.md) for the full walkthrough of the web UI, JSON API and MCP server.

## How You Use It

| Surface | What it's for |
|---------|---------------|
| **Web UI** | Day-to-day operations: dashboard, servers, apps, scripts, backups |
| **JSON API** (`/api/v1`) | Scripting and external integrations (Bearer API token) |
| **MCP server** (`/mcp`) | Let MCP-compatible AI agents drive the fleet |
| **CLI** (`cli/`) | `conductor fleet`, `situation`, `server show` — for terminals, scripts and CI. Exit codes are a contract, and `conductor auth login` reads the token from stdin so it never reaches argv |


## Documentation

- [`documents/USAGE.md`](documents/USAGE.md) — how to use Conductor
- [`documents/PILLARS.md`](documents/PILLARS.md) — the seven product pillars and where help is wanted
- [`documents/roadmap/`](documents/roadmap/) — the delivery sequence and one page per capability
- [kuickr.co/conductor](https://kuickr.co/conductor/docs/00-index.md) — the published docs hub (guides, roadmap)

## Contributing

Contributions are welcome. The fastest way in:

1. Read [`documents/PILLARS.md`](documents/PILLARS.md) and pick a pillar — each lists concrete "where help is wanted" entry points.
2. Skim the matching page in [`documents/roadmap/`](documents/roadmap/).
3. Open an issue or PR. See [`AGENTS.md`](AGENTS.md) for collaboration and documentation conventions.

## Tech

Rails 8 · Turbo · Importmaps · Tailwind · Solid Queue · ActionCable · SSH-based execution (no agent to install on your servers).

## License & Usage

Conductor is **source-available** under the [Elastic License 2.0](LICENSE).

In plain terms:

- ✅ **You may** use, run, and self-host Conductor — including for your own commercial business and your own infrastructure.
- ✅ **You may** modify it, fork it, and redistribute it (with notices intact).
- ❌ **You may not** provide Conductor to third parties as a hosted or managed service — i.e. you can't take this code and run a competing Conductor cloud.

If you want to offer Conductor as a managed service, talk to us about a commercial license.
