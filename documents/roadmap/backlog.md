# Conductor — Roadmap & Backlog

Gap analysis vs a hosted Rails PaaS, mapped to the 6 strategic pillars. Detailed plans live alongside this file as `plan-*.html`.

_Index in Markdown; individual plan pages stay HTML._ · Updated 2026-06-20.

> **Build order:** this file is the *spine* (what each item is). For *what order to build them in*, see **[`00-delivery-sequence.html`](00-delivery-sequence.html)** ([md](00-delivery-sequence.md)) — the dependency-wave overlay.

## Thesis

Conductor is the **control plane for self-hosted Rails ops across a fleet** — apps, servers, routing, databases, backups, and provider APIs, across **Kamal, native, and Docker** deploys, driven by web UI, CLI, and **AI agents over MCP**. The moat is the _combination_ (multi-host + hybrid deploy + provider APIs + Postgres ops + continuous maintenance + agent-native control), not "deploy Rails on a VPS" — that lane is a hosted PaaS's.

### Where Conductor already beats a hosted PaaS

- **Agent-native** — a full MCP server, CLI, and API. A hosted PaaS has none of this.
- **Hybrid backends** — Kamal _and_ native _and_ Docker. Hosted PaaS panels are native-only.
- **Self-hosted / source-available** (Elastic License) vs a hosted SaaS panel.
- **Provider-API orchestration** (SES, R2, Cloudflare, Hetzner) + Postgres cluster ops + continuous maintenance.

## Recently shipped

- **MCP OAuth connect (browser sign-in for agents)** — **shipped 2026-07-27**: Conductor is now an OAuth 2.1 authorization server for its own `/mcp` endpoint (discovery, dynamic client registration, PKCE, refresh tokens, RFC 8707 audience binding, org-bound tokens), so Codex / claude.ai / Cursor connect with a browser login instead of a pasted bearer token. Static tokens still work. (See [../conductor/plans/06-mcp-oauth-connect.md](../conductor/plans/06-mcp-oauth-connect.md).)
- **Deploy Kamal apps through Conductor (control machine)** — **live-validated 2026-06-19**: Conductor's container clones the repo and builds on the target's docker daemon over SSH, then deploys. First clean end-to-end deploy proven on a real app. (See [01-kamal-control-machine.html](01-kamal-control-machine.html).)
- **GitHub App & deploy keys (private repos), Kamal slice** — short-lived installation tokens + auto-installed deploy keys, plus a browser **Integrations** page. Native/raw-Docker clone auth and commit-status reporting remain. (See [02-github-app.html](02-github-app.html).)
- Cron / scheduled jobs, server hardening/auto-update/audit, Postgres clusters (per-app DB on a shared cluster), MCP server + token + audit log (secret-redacted), org-scoped `/api/v1` + org-aware MCP, kamal env bridge + status sync. `app-one.example.com` + `app-three.example.com` live on the shared fleet box (multi-app proven).

## Backlog — gaps to fully replace a hosted Rails PaaS

Ordered by priority. **P0** = blocks the core "push → deploy" loop · **P1** = expected parity · **P2** = polish/breadth.

| Plan | Pillar | Priority | Effort | Status |
|---|---|---|---|---|
| [Deploy Kamal apps through Conductor (control machine)](01-kamal-control-machine.html) | Runtime Backends | P0 | M | ✅ Done (2026-06-19) |
| [GitHub App & deploy keys (private repos)](02-github-app.html) | Provider Automation | P0 | M | 🟡 Partial — Kamal shipped; Native/raw-Docker parity remains |
| [Auto-deploy on git push](03-auto-deploy-push.html) | Runtime Backends | P0 | M | ✅ Done (2026-06-20) |
| [Rollbacks & release history](04-rollbacks.html) | Runtime Backends | P1 | M | 🟡 Partial — Kamal one-click rollback + release history; native deferred |
| [Background worker management](05-background-workers.html) | Runtime Backends | P1 | M | 🟡 Partial — Solid Queue visibility only; control remains |
| [Live app log streaming in the UI](06-app-logs.html) | Fleet Control | P1 | M | 🟡 Partial — bounded polling shipped; follow stream remains |
| [Server provisioning via provider APIs](07-server-provisioning.html) | Provider Automation | P1 | L | Planned |
| [Seed management & idempotency check](08-seed-management.html) | Runtime Backends | P1 | S | 🔄 Apply+record SHIPPED (2026-07-13): `SeedApplication` ledger + a one-shot `seed_on_next_deploy` that runs `db:seed` in the deployed container and records status + db/seeds.rb digest + output (KamalDeployer; UI toggle + MCP). Preflight "seeds" gate now has a real writer + blocks on a failed run. Remains: standalone (no-deploy) run, idempotency scan of seeds.rb, non-kamal support |
| [In-container task runner (db:seed / rake / migrate)](09-app-task-runner.html) | Agent-native | **P0** | M | Planned · **Heroku-DX** |
| [Multi-tenant MCP (anyone can deploy)](14-multi-tenant-mcp.html) | Agent-native | P1 | M | ✅ Done (2026-06-20) |
| [MCP wire-protocol transport](15-mcp-wire-protocol.html) | Agent-native | P1 | M | 🟡 Partial — JSON-RPC core shipped; resource/SSE/live-client evidence remain |
| [Deploy hooks (pre/post commands)](10-deploy-hooks.html) | Runtime Backends | P2 | S | Planned |
| [Web console (rails console / shell)](11-web-console.html) | Fleet Control | **P1** | M | Planned · **Heroku-DX** |
| [Alerts & notifications](12-alerts.html) | Continuous Maintenance | P2 | M | 🟡 Partial — global failure emails only; org pipeline remains |
| [Redis & MySQL accessories](13-accessories.html) | Data & Backups | P2 | M | Planned |
| [Secretless deploys (vault-resolved secrets)](16-secretless-deploys.html) | Agent-native | P1 | M | Planned |
| [Reactive statuses everywhere (Turbo Streams)](17-reactive-statuses.html) | Fleet Control | P1 | M | 🔄 In progress (slice 1 done 2026-06-22) |
| [Per-app proxy mode (Caddy or kamal-proxy)](18-per-app-proxy-mode.html) | Routing & edge | P1 | M | **Spec'd** (`docs/plans/per-app-proxy-mode.md`, 2026-07-09) · edge-per-box + kamal-proxy→Caddy migration; depends on ADR 0001 |
| [Cloudflare R2 integration](19-r2-integration.html) | Provider Automation | P1 | M | Planned |
| [AWS SES + SNS messaging (email + SMS)](20-ses-sns-messaging.html) | Provider Automation | P1 | M | Planned · **+ event-level observability spec'd** (`docs/conductor/plans/05-ses-observability.md`) |
| [Backup restore + verification (R2)](21-backup-restore.html) | Data & Backups | P0 | M | Planned |
| [Caddy management console + per-app multi-subdomain](22-caddy-console.html) | Routing & edge | P1 | M | Planned |
| [Deploy-executor rework (isolate kamal from the web container)](23-deploy-executor.html) | Runtime Backends | P1 | L | Planned · **architecture** |
| Migration lifecycle: status, pending/drift detection, gated run, failure remediation | Runtime Backends | **P0** | M | 🔄 Post-deploy gated run SHIPPED (KamalDeployer, kamal only, 2026-07-11); **Deploy Preflight gate SHIPPED** (2026-07-13, `DeployPreflight` — blocks on at-risk audit / deploy-hold / failed-seed, force override). NOTE: the preflight's migration row is a *capability* check (is a post-deploy gate present), **not** a live pending-migration/drift probe — real pre-deploy drift detection, docker/native gating, and failure remediation remain |
| [Operability gaps: resolving failures · schema state · easy backups · per-app schedules · job control](../conductor/plans/08-operability-gaps.md) | Fleet Control | **P0** | M | **Spec'd 2026-07-29** — found by designing the app/fleet/jobs pages against real data. Includes the *live* schema-state probe the row above still lacks, plus the per-app checklist (one-click defaults, exposed over MCP). Mockups: kuickr `conductor/design` |
| [Two-identity servers (root=automation, deploy=app ops) + server automation/upgrades as root](25-two-identity-servers.html) | Continuous Maintenance | P1 | M | Planned · **security split** |
| [App transfer between boxes + dedicated database containers](26-app-transfer.html) | Runtime Backends | P1 | L | **Spec locked** (A–D resolved 2026-07-26) · dedicated-DB + KamalProxyAdapter · ready to build |
| [SES email observability (event-level, via SNS)](27-ses-observability.html) | Provider Automation | P1 | M | Draft · **annotate** · flight-recorder for slot 20 · (`plans/05`) |
| [Retire per-app deploy scripts — every app deploys through Conductor](31-retire-per-app-deploy-scripts.html) | Runtime Backends | **P0** | M | **Spec'd 2026-08-03** — three apps (InventList, platepose, minimalnarrow) deploy via repo scripts Conductor never sees, so it holds no release record and can offer them no rollback. Conductor's stale record for app 13 was taken as a release baseline by an audit and produced a wholly fabricated migration protocol. `ReleaseDriftDetector` now SURFACES this (`unrecorded`); this slot removes the cause. Unblocked by ADR 0003 docker-on-Caddy cutover — the reason the scripts exist has expired. Also closes the root-SSH gap. |

## Critical path

The Kamal control-machine path and GitHub webhook auto-deploy are shipped. The next P0 product slice is:

1. [In-container task runner](09-app-task-runner.html) — UI/MCP execution for seed, migrate, rake, and runner commands; required to finish runtime-agnostic seed management.

In parallel, finish slot 02 clone-auth parity for Native/raw-Docker deploys. Then P1 parity—rollbacks, managed workers, true app-log streaming, provisioning, and seed idempotency—closes the remaining trust and Heroku-DX gaps.
