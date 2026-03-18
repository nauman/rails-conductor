# Logs & Observability Plan

## Pillar
Continuous maintenance

## Status
Partial

## Current Reality

- Deploy logs and script output stream in real time via ActionCable.
- There is no centralized operational log model across apps, servers, and routing.
- The older Portainer/agent assumption is too narrow for the current SSH-first vision.

## Goal

Give operators practical access to recent logs across apps, servers, Caddy, and maintenance workflows without requiring immediate SSH access.

## Scope

- Log access for Docker apps, native apps, Caddy, and provisioning/deploy flows
- Streaming for active operations
- Recent log retrieval for debugging after the fact
- Basic filtering by app, server, source, and time window
- Operational storage strategy for short-term retention

## Non-goals

- Full log analytics pipeline in v1
- Long-term SIEM-style retention and search
- Deep query language or arbitrary dashboards

## Core Workflows

1. View live deploy or provisioning output.
2. Open recent app or server logs when an issue appears in the dashboard.
3. Filter logs by app, server, or source to debug the problem quickly.
4. Preserve enough recent history to support post-failure inspection.

## Requirements

1. Support log access without depending on Portainer or an agent.
2. Treat live streaming and recent retrieval as separate but connected workflows.
3. Support Docker, native Puma/systemd, and Caddy log sources.
4. Expose logs through the same operational model used by fleet issues.
5. Keep retention strategy explicit: in-memory, DB, object storage, or hybrid.

## Dependencies

- `docs/plans/monitoring-ops.md`
- `docs/plans/routing-caddy.md`
- runtime backend log source definitions

## Milestones

1. Define log source inventory and access method per runtime.
2. Add recent-log retrieval endpoints and UI views.
3. Add filtering by app, server, source, and time window.
4. Add short-term retention and download/export rules.

## Risks

- High log volume can overwhelm naive storage choices.
- Different runtime backends expose logs differently.
- Logging strategy can sprawl into analytics if not constrained.

## Open Questions

- Persist recent logs in DB, object storage, or a hybrid?
- What retention window is enough for operational debugging?
- Which sources should ship first: deploys, app logs, Caddy logs, or system logs?
