# Conductor

**A control plane for self-hosted Rails operations.** One place to run, monitor, and maintain your apps across mixed infrastructure — whether they run with Kamal and Docker or natively with Caddy and Puma.

Conductor isn't a hosting platform and it doesn't lock you into one deployment style. It connects to servers you already own over SSH, and turns Caddy, Postgres, backups, and provider APIs into one coherent operational layer.

> **Status:** early and honest. The fleet dashboard, SSH execution, Docker deploys, backups, alerts, recurring jobs, and a baseline Caddy client work today. Routing, provider automation, restore, and drift detection are in progress. See [`docs/PILLARS.md`](docs/PILLARS.md) for the real maturity of each area.

---

## Why

If you run a handful of apps across a few VPSs, you've probably SSH'd into each box one too many times and built `/admin/server` panels inside every app just to see what's happening. Conductor is the single pane of glass instead:

- **See the whole fleet in seconds** — health, last deploy, current issues across every server and app.
- **Deploy your way** — Docker/Kamal *and* native Puma/systemd under one control plane.
- **Take action, not just observe** — deploy, restart, run scripts, manage routes, and back up databases from the UI, API, or AI chat.
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
- JSON API, an **MCP server** for AI agents, and a natural-language chat interface

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

See [`docs/USAGE.md`](docs/USAGE.md) for the full walkthrough of the web UI, JSON API, MCP server, and chat.

## How You Use It

| Surface | What it's for |
|---------|---------------|
| **Web UI** | Day-to-day operations: dashboard, servers, apps, scripts, backups, chat |
| **JSON API** (`/api/v1`) | Scripting and external integrations (Bearer API token) |
| **MCP server** (`/mcp`) | Let MCP-compatible AI agents drive the fleet |
| **Chat** (`/conversations`) | Natural-language orchestration over the same tools |

> A dedicated `conductor` command-line tool is on the roadmap. For now, the JSON API is the way to drive Conductor from scripts.

## Documentation

- [`docs/USAGE.md`](docs/USAGE.md) — how to use Conductor
- [`docs/PILLARS.md`](docs/PILLARS.md) — the six product pillars and where help is wanted
- [`docs/scenarios/`](docs/scenarios/) — end-to-end product flows (publish a route, restore a backup, create a server, connect a domain, move an app, detect drift)
- [`docs/plans/INDEX.md`](docs/plans/INDEX.md) — capability plans grouped by pillar
- [`docs/VISION.md`](docs/VISION.md) — the longer-term direction
- [`docs/INDEX.md`](docs/INDEX.md) — full documentation map

## Contributing

Contributions are welcome. The fastest way in:

1. Read [`docs/PILLARS.md`](docs/PILLARS.md) and pick a pillar — each lists concrete "where help is wanted" entry points.
2. Skim the relevant plan in [`docs/plans/INDEX.md`](docs/plans/INDEX.md) and any matching scenario.
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
