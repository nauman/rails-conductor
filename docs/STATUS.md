# Conductor — Status Map

A living snapshot of **what's built, what's planned, and what's still missing**, across the 7 strategic pillars. The canon for *why* is `docs/VISION.md`; the canon for *what next* is `docs/roadmap/backlog.md`. This file is the at-a-glance bridge.

_Last updated: 2026-07-21._

## ✅ Built & live

| Pillar | Shipped & running |
|---|---|
| **Fleet control** | dashboard; fleet/app/server/deploy status; reactive status badges (Turbo Streams); bounded SSH log snapshots with browser polling; secret-redacted MCP audit log |
| **Runtime backends** | 3 runtimes — Kamal (control-machine, build-over-SSH), Docker (raw), Native (Puma/systemd); auto-deploy on git push; self-deploy + boot reconciler; pre-flight secret validation; per-app deploy notes |
| **Routing & edge** | Caddy route CRUD via Admin API (add/remove domain); per-app domains |
| **Provisioning & provider automation** | GitHub App + auto-installed deploy keys for Kamal checkouts; SSH key vault; provider tagging |
| **Data & backups** | Postgres clusters + per-app DB provisioning; `pg_dump` backups + scheduling → R2; DB pull (remote→local) |
| **Continuous maintenance** | cron/scheduled jobs; server hardening / auto-update / audit; global-admin email alerts for backup/deploy/server failures |
| **Agent-native control** | MCP server (7 enum tools); JSON-RPC Streamable HTTP core; **OAuth 2.1 connect (browser sign-in, dynamic client registration, PKCE, org+audience-bound tokens, revocable per client)**; multi-tenant org-scoped + read-only scope + token-issuance UI; AI chat orchestration; `/mcp/skill`; **Conductor deploys itself** |

_Verification history lives under `docs/sessions/`; repository behavior is gated by `bin/ci`._

## 🔜 Planned (roadmap)

| Pillar | Slots |
|---|---|
| **Fleet control** | 06 true app-log follow stream *(polling slice shipped)* · 17 reactive statuses *(slice 1 ✅)* · 11 web console *(Heroku-DX)* |
| **Runtime backends** | 02 Native/raw-Docker private clone auth · 04 rollbacks · 05 managed workers *(visibility slice shipped)* · 08 seed idempotency/standalone run *(Kamal apply+record shipped)* · 09 task runner *(Heroku-DX)* · 10 deploy hooks · 16 secretless deploys · **23 deploy-executor rework** |
| **Routing & edge** | 18 per-app proxy mode · 22 Caddy console + multi-subdomain |
| **Provisioning & provider automation** | 07 server provisioning (Hetzner) · 19 R2 · 20 SES + SNS |
| **Data & backups** | 21 backup restore + verify *(P0)* · 13 Redis/MySQL accessories |
| **Continuous maintenance** | 12 org-scoped alert pipeline/webhooks/dedup *(global email slice shipped)* |
| **Agent-native control** | 15 MCP resource/SSE decision + real-client acceptance *(JSON-RPC core shipped)* · 16 secretless (capstone) |

## ❌ Missing / not yet slotted

| Area | Gap |
|---|---|
| **Architecture** | deploy-executor rework — *now slot 23* (isolate kamal from the web container) |
| **Runtime backends** | runtime-agnostic dev commands (Heroku-DX: console/exec/run-task as one button across kamal *and* native) — slots 09 + 11; **migration lifecycle — status/pending/drift detection + gated run + failure remediation — slot 24 (caused 2 prod 500s); seed idempotency — slot 08** |
| **Routing & edge** | wildcard certs, DNS-driven routing, cert/drift reconcile workflows |
| **Provider automation** | Cloudflare DNS CRUD; Hetzner VM create (deferred); deeper R2/SES management |
| **Data & backups** | PITR; scheduled restore-verification (partly slot 21) |
| **Continuous maintenance** | drift detection; centralized log storage/analytics; richer health checks; **two-identity servers (root=automation/upgrades, deploy=app ops) + server automation as root — slot 25** |
| **Agent-native** | Conductor's own CLI (future); secretless is the trust capstone |
| **Cross-cutting** | dark mode; deeper multi-host orchestration |

## Where we're heading (the through-line)

1. **Agent-native + secretless** — every capability is also a clean, audited MCP tool with no secret exposure. The moat.
2. **Connected-services hub** — R2 / SES / SNS / Caddy / Hetzner as monitor-and-manage (slots 19–22).
3. **Architecture rework** — separate control plane from an isolated deploy executor, so "self-hosted Heroku" is robust, not a reconciler band-aid (slot 23).
4. **Heroku-DX** — true streaming logs, plus console/exec/run-task across runtimes (slots 06, 09, and 11), so working with a deployed app feels like Heroku.
