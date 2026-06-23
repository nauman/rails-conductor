# Conductor — Roadmap & Backlog

Gap analysis vs **Hatchbox.io**, mapped to the 6 strategic pillars. Detailed plans live alongside this file as `plan-*.html`.

_Index in Markdown; individual plan pages stay HTML._ · Updated 2026-06-20.

> **Build order:** this file is the *spine* (what each item is). For *what order to build them in*, see **[`00-delivery-sequence.html`](00-delivery-sequence.html)** ([md](00-delivery-sequence.md)) — the dependency-wave overlay.

## Thesis

Conductor is the **control plane for self-hosted Rails ops across a fleet** — apps, servers, routing, databases, backups, and provider APIs, across **Kamal, native, and Docker** deploys, driven by web UI, CLI, and **AI agents over MCP**. The moat is the _combination_ (multi-host + hybrid deploy + provider APIs + Postgres ops + continuous maintenance + agent-native control), not "deploy Rails on a VPS" — that lane is Hatchbox's.

### Where Conductor already beats Hatchbox

- **Agent-native** — a full MCP server, CLI, and API. Hatchbox has none of this.
- **Hybrid backends** — Kamal _and_ native _and_ Docker. Hatchbox is native-only.
- **Self-hosted / source-available** (Elastic License) vs Hatchbox's hosted SaaS panel.
- **Provider-API orchestration** (SES, R2, Cloudflare, Hetzner) + Postgres cluster ops + continuous maintenance.

## Recently shipped

- **Deploy Kamal apps through Conductor (control machine)** — **live-validated 2026-06-19**: Conductor's container clones the repo and builds on the target's docker daemon over SSH, then deploys. First clean end-to-end deploy proven on a real app. (See [01-kamal-control-machine.html](01-kamal-control-machine.html).)
- **GitHub App & deploy keys (private repos)** — cross-org installation tokens + auto-installed deploy keys, plus a browser **Integrations** page to configure the GitHub App. (See [02-github-app.html](02-github-app.html).)
- Cron / scheduled jobs, server hardening/auto-update/audit, Postgres clusters (per-app DB on a shared cluster), MCP server + token + audit log (secret-redacted), org-scoped `/api/v1` + org-aware MCP, kamal env bridge + status sync. `kuickr.co` + `wiseherds.com` live on the shared fleet box (multi-app proven).

## Backlog — gaps to fully replace Hatchbox

Ordered by priority. **P0** = blocks the core "push → deploy" loop · **P1** = expected parity · **P2** = polish/breadth.

| Plan | Pillar | Priority | Effort | Status |
|---|---|---|---|---|
| [Deploy Kamal apps through Conductor (control machine)](01-kamal-control-machine.html) | Runtime Backends | P0 | M | ✅ Done (2026-06-19) |
| [GitHub App & deploy keys (private repos)](02-github-app.html) | Provider Automation | P0 | M | ✅ Done |
| [Auto-deploy on git push](03-auto-deploy-push.html) | Runtime Backends | P0 | M | ✅ Done (2026-06-20) |
| [Rollbacks & release history](04-rollbacks.html) | Runtime Backends | P1 | M | Planned |
| [Background worker management](05-background-workers.html) | Runtime Backends | P1 | M | Planned |
| [Live app log streaming in the UI](06-app-logs.html) | Fleet Control | P1 | M | ✅ Done (2026-06-21) |
| [Server provisioning via provider APIs](07-server-provisioning.html) | Provider Automation | P1 | L | Planned |
| [Seed management & idempotency check](08-seed-management.html) | Runtime Backends | P1 | S | Planned |
| [In-container task runner (db:seed / rake / migrate)](09-app-task-runner.html) | Agent-native | P1 | M | Planned |
| [Multi-tenant MCP (anyone can deploy)](14-multi-tenant-mcp.html) | Agent-native | P1 | M | ✅ Done (2026-06-20) |
| [MCP wire-protocol transport](15-mcp-wire-protocol.html) | Agent-native | P1 | M | Planned |
| [Deploy hooks (pre/post commands)](10-deploy-hooks.html) | Runtime Backends | P2 | S | Planned |
| [Web console (rails console / shell)](11-web-console.html) | Fleet Control | P2 | M | Planned |
| [Alerts & notifications](12-alerts.html) | Continuous Maintenance | P2 | M | Planned |
| [Redis & MySQL accessories](13-accessories.html) | Data & Backups | P2 | M | Planned |
| [Secretless deploys (vault-resolved secrets)](16-secretless-deploys.html) | Agent-native | P1 | M | Planned |
| [Reactive statuses everywhere (Turbo Streams)](17-reactive-statuses.html) | Fleet Control | P1 | M | 🔄 In progress (slice 1 done 2026-06-22) |
| [Per-app proxy mode (Caddy or kamal-proxy)](18-per-app-proxy-mode.html) | Routing & edge | P1 | M | Planned |

## Critical path

The two P0 deploy blockers (Kamal control machine, GitHub App) are **done**. Remaining P0:

1. [Auto-deploy on push](03-auto-deploy-push.html) — the signature Hatchbox loop: push → webhook → deploy.

Then P1 parity (rollbacks, workers, app logs, provisioning, **seed management**, **in-container task runner**) closes the rest of the gap while the agent/MCP surface keeps the differentiation. The seed-management and task-runner items were surfaced live: a Conductor deploy runs `db:prepare` only, so an app whose demo login depends on seed-created data silently broke until seeds were run by hand.
