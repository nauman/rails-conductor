# Platform Overview Plan

## Goal
Ship a Rails-first Ops platform that provisions infrastructure, deploys apps, manages routing, and provides monitoring + backups in one panel.

## Scope
- Sequence the platform into phases that can be delivered independently.
- Define cross-cutting dependencies and shared primitives.

## Non-goals
- Full multi-tenant billing implementation in phase 1.
- Complete replacement for every PaaS feature (focus on core ops).

## Phases

### Phase 0 — Foundations
- Docs structure, core data models, auth, and layout.
- Manual data entry for VMs, backups, and storage.

### Phase 1 — Observability MVP
- VM health snapshots.
- R2 backup status.
- Active Storage usage.

### Phase 2 — Ops Automation
- Provisioning + deployment pipelines.
- Routing API sync.
- Logs + alerts.

### Phase 3 — Productization
- Add-ons, billing tiers, GPT assistant, and onboarding flows.

## Dependencies
- Data models for workspace, hosts, apps, and credentials.
- Background job runner for polling and automation.

## Risks
- Overbuilding without customer feedback.
- External API drift (Hetzner, Cloudflare, Portainer).

## Open Questions
- Single global Caddy vs per-region edge?
- Multi-tenant DB strategy (shared vs per-tenant)?
