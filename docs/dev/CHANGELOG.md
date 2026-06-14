# Changelog

Lightweight shipped-history summary. For implementation detail and verification, see `docs/sessions/`.

## 2026-03-12

- Fixed schema mismatches in `servers` and `deployments`
- Added `Deployment` server association support
- Replaced deploy-page polling with ActionCable log streaming
- Added deployment seed data for realistic local state

Source: `docs/sessions/2026-03-12-production-readiness.md`

## 2026-03-25

- Added recurring ops baseline scheduling for metrics refresh, container sync, and scheduled backup dispatch
- Added SSH-backed `CaddyClient` service with route fetch/upsert/remove, config snapshots, and basic validation
- Wired add/remove domain tools to the real Caddy client and added test coverage

Source: `docs/sessions/2026-03-28-routing-baseline-and-doc-realignment.md`
