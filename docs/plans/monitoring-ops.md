# Monitoring & Ops Plan

## Goal
Provide a single-pane dashboard for host health, backups, storage, and deployments.

## Scope
- VM health snapshots (CPU, memory, disk, uptime).
- App health checks and uptime.
- Alerting stubs for degraded status.

## Non-goals
- Full metrics time-series charts in v1.

## Milestones
1. Host heartbeat + polling job.
2. Health snapshot storage model.
3. Dashboard UI + status badges.

## Dependencies
- Host agent or polling endpoint.
- Job runner and cache.

## Risks
- Polling load across many hosts.

## Open Questions
- Webhooks vs polling?
- How often to refresh without spiking costs?
