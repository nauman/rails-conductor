# Plans Index

`docs/plans/` is the product-requirements layer for Conductor. Use these plans as the canonical build map, grouped by strategic pillar and current status.

> **Canonical pillars (reconciled 2026-06-23): 7** — the six below **plus _Agent-native control_** (added 2026-06-23, leads the moat); Routing & edge stays standalone. `docs/VISION.md` is the single source of truth for pillars + moat. The March 2026 pillars-audit %s are stale (much shipped since).

## Source of Truth

- Strategy: `docs/VISION.md`
- Current reality: `docs/analysis/pillars-audit-2026-03-19.md`
- User use cases: `docs/scenarios/INDEX.md`
- Session history: `docs/sessions/INDEX.md`
- Legacy feature inventory: `docs/backlogs/prd.json`

## Build Order

1. `docs/plans/recurring-ops-schedule.md` — turn existing jobs into actual continuous operations
2. `docs/plans/caddy-client.md` + `docs/plans/routing-caddy.md` — make native and multi-app hosting reachable
3. `docs/plans/cloudflare.md` + `docs/plans/domains-dns.md` + `docs/plans/provisioning-hetzner.md` + `docs/plans/server-bootstrap.md` — complete domain, DNS, server creation, and bootstrap automation
4. `docs/plans/monitoring-ops.md` + `docs/plans/logs-observability.md` — deepen daily-use operational workflows
5. `docs/plans/backups-r2.md` + `docs/plans/postgres-restore.md` + `docs/plans/data-layer.md` — complete restore, verification, and database operations
6. `docs/plans/deployment-kamal.md` — revisit richer Docker backend support after routing and provider automation are in place

## Implemented

| File | Covers | Pillar |
| --- | --- | --- |
| `docs/plans/conductor-phase-0-1.md` | Core models, credentials, apps, backups, dashboard shell | Fleet control |
| `docs/plans/conductor-phase-2-ssh.md` | SSH key vault, agentless execution, polling foundation | Fleet control |
| `docs/plans/conductor-phase-3-deployment.md` | Docker deploy via SSH with streaming output | Runtime backends |
| `docs/plans/monitoring-ops.md` | Dashboard, host health, app status, backup visibility | Fleet control |
| `docs/plans/production-readiness.md` | Schema fixes, deploy streaming, production-readiness cleanup | Cross-cutting |

## Partially Implemented

| File | Covers | Main Gap | Pillar |
| --- | --- | --- | --- |
| `docs/plans/recurring-ops-schedule.md` | Scheduled metrics, container sync, backup triggering | Recurring jobs now run; failure surfacing and queue tuning remain | Continuous maintenance |
| `docs/plans/caddy-client.md` | Caddy Admin API service boundary and failure model | Baseline SSH-backed client exists; route persistence, richer validation, and cert/drift workflows remain | Routing and edge |
| `docs/plans/backups-r2.md` | `pg_dump` to R2 with scheduling | Restore, verification, PITR | Data and backups |
| `docs/plans/cloudflare.md` | Cloudflare DNS and R2 credentials/setup | Actual API calls and validation | Provisioning and provider automation |
| `docs/plans/domains-dns.md` | Domain management via Cloudflare | DNS CRUD, validation, alerts | Routing and edge |
| `docs/plans/routing-caddy.md` | Caddy Admin API route sync | Baseline route CRUD exists; persistence, reconciliation, deploy hooks, and certificate/drift workflows remain | Routing and edge |
| `docs/plans/server-bootstrap.md` | Post-creation host bootstrap workflow | No end-to-end bootstrap automation | Provisioning and provider automation |
| `docs/plans/ssh-keys.md` | SSH key storage and management | Hetzner key registration | Provisioning and provider automation |
| `docs/plans/logs-observability.md` | Centralized log access | Storage, filters, analytics | Continuous maintenance |
| `docs/plans/postgres-restore.md` | Restore flow, verification, and safety model | Restore workflow does not exist | Data and backups |
| `docs/plans/sc-001-kamal-monitoring.md` | Monitoring dashboard for Docker apps | Dashboard widgets and scheduling | Fleet control |
| `docs/plans/multi-tenancy.md` | Orgs, scoping, invitations, admin, billing | Invitations, admin, API scoping, billing remain | Cross-cutting (Tenancy) |
| `docs/plans/onboarding.md` | First-run org naming + empty-state guidance | Building now | Cross-cutting (Tenancy) |

## Stale or Deferred

| File | Covers | Why Stale / Deferred | Pillar |
| --- | --- | --- | --- |
| `docs/plans/deployment-kamal.md` | Dynamic Kamal config generation | Current implementation uses SSH + Docker; revisit later | Runtime backends |
| `docs/plans/provisioning-hetzner.md` | Hetzner API VM creation | Never started | Provisioning and provider automation |
| `docs/plans/data-layer.md` | Managed Postgres strategy | Over-scoped for current product stage | Data and backups |
| `docs/plans/active-storage.md` | Managed-app blob visibility and cleanup | Deferred until a justified, safe integration path exists | Data and backups |
| `docs/plans/portainer-docker.md` | Docker inventory beyond managed app lifecycle | Deferred; core Docker operations already exist and Portainer is dropped | Fleet control |
| `docs/plans/gpt-assistant.md` | AI ops helper | Deferred until core control plane is stable | Cross-cutting |
| `docs/plans/addons-billing.md` | Tiers and billing | Deferred until core is stable | Cross-cutting |
| `docs/plans/workspaces.md` | Multi-tenant workspace model | Placeholder only | Cross-cutting |

## Still Current Reference

| File | Covers | Pillar |
| --- | --- | --- |
| `docs/plans/platform-overview.md` | Four-phase roadmap across all domains | Cross-cutting |
| `docs/plans/INDEX.md` | Navigation and status map for plans | Cross-cutting |

## Rules

- Treat each plan as a PRD for one capability area.
- Update status here when a plan moves from deferred to active, or from partial to implemented.
- Record shipped work in `docs/sessions/INDEX.md` and linked session docs, then reflect it here.
- Keep `docs/analysis/pillars-audit-2026-03-19.md` aligned with this index.
