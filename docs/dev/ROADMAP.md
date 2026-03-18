# Roadmap

This is a compact roadmap snapshot. For the canonical plan set, use `docs/plans/INDEX.md`. For current reality, use `docs/analysis/pillars-audit-2026-03-19.md`.

## Shipped Foundation

- [x] Core models for servers, credentials, apps, deployments, and backups
- [x] SSH-based remote execution and provisioning scripts
- [x] Basic Docker deployment with ActionCable log streaming
- [x] Dashboard visibility for fleet status and critical issues
- [x] Backup creation and scheduling to S3/R2-compatible storage
- [x] Critical email alerts for offline servers, failed backups, and failed deploys

## Next Build Order

### 1. Routing and Edge
- [ ] Build Caddy Admin API client
- [ ] Add route CRUD, validation, and reconciliation
- [ ] Make native and multi-app hosting reachable

### 2. Provisioning and Provider Automation
- [ ] Add Hetzner API provisioning
- [ ] Add Cloudflare DNS automation
- [ ] Add control-panel flows for domains, R2, and SES

### 3. Continuous Maintenance
- [ ] Finish recurring jobs for metrics, sync, and checks
- [ ] Add drift detection, cert monitoring, and server updates
- [ ] Add webhook/chat notifications

### 4. Data and Backups
- [ ] Add Postgres restore
- [ ] Add backup verification
- [ ] Add DB health and cluster operations

### 5. Runtime Backends
- [ ] Revisit Kamal backend integration
- [ ] Evaluate ONCE-compatible execution where useful
- [ ] Add richer release tracking and rollback

## Decision Log

- 2026-03-19: `docs/plans/` is the canonical PRD layer; `docs/dev/` is summary-only.
- 2026-03-19: Build order prioritizes routing and provider automation before deeper runtime abstraction.
