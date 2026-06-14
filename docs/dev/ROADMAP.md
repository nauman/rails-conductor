# Roadmap

This is a compact roadmap snapshot. For the canonical plan set, use `docs/plans/INDEX.md`. For current reality, use `docs/analysis/pillars-audit-2026-03-19.md`.

## Post-Audit Summary

- Fleet control is the strongest shipped area: dashboard, metrics collection, managed container visibility, alerts, and SSH primitives exist.
- Routing and edge are still the hardest product blocker: native deploys are not truly live until Caddy route management exists.
- Provider automation is structurally planned but mostly unimplemented: Hetzner and Cloudflare still need real API clients.
- Data and backups are half-done: backup creation works, restore and verification are the trust gap.
- Two plans are intentionally deferred after the audit: Active Storage and Portainer/Docker deep inventory.

## Shipped Foundation

- [x] Core models for servers, credentials, apps, deployments, and backups
- [x] SSH-based remote execution and provisioning scripts
- [x] Basic Docker deployment with ActionCable log streaming
- [x] Dashboard visibility for fleet status and critical issues
- [x] Backup creation and scheduling to S3/R2-compatible storage
- [x] Critical email alerts for offline servers, failed backups, and failed deploys

## Next Build Order

### 1. Continuous Maintenance Baseline
- [x] Schedule recurring metrics refresh, container sync, and backup dispatch
- [ ] Surface recurring-job failure patterns and deeper freshness history

### 2. Routing and Edge
- [x] Build Caddy Admin API client
- [x] Add baseline route CRUD and validation via domain tools
- [ ] Add route persistence, reconciliation, and deploy-hook integration
- [ ] Make native and multi-app hosting reachable

### 3. Provisioning and Provider Automation
- [ ] Add Hetzner API provisioning
- [ ] Add Cloudflare DNS automation
- [ ] Add control-panel flows for domains, R2, and SES

### 4. Continuous Maintenance
- [ ] Add drift detection, cert monitoring, and server updates
- [ ] Add webhook/chat notifications

### 5. Data and Backups
- [ ] Add Postgres restore
- [ ] Add backup verification
- [ ] Add DB health and cluster operations

### 6. Runtime Backends
- [ ] Revisit Kamal backend integration
- [ ] Evaluate ONCE-compatible execution where useful
- [ ] Add richer release tracking and rollback

## Decision Log

- 2026-03-19: `docs/plans/` is the canonical PRD layer; `docs/dev/` is summary-only.
- 2026-03-19: Build order prioritizes routing and provider automation before deeper runtime abstraction.
- 2026-03-25: Active Storage and Portainer/Docker deep inventory were deferred after the full plan audit.
- 2026-03-25: Recurring operations scheduling moved from planning into implementation.
- 2026-03-25: The SSH-first `CaddyClient` baseline shipped; remaining routing work moved to persistence, reconciliation, and deploy integration.
