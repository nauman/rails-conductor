# Logs & Observability Plan

## Goal
Centralize container, Caddy, and Rails logs for debugging and alerts.

## Scope
- Pull logs via Portainer API or agent.
- Store recent logs and link to download.
- Basic filters for app/environment.

## Non-goals
- Full log analytics pipeline in v1.

## Milestones
1. Log source inventory and access credentials.
2. Log fetch and streaming endpoint.
3. UI log viewer with filters.

## Dependencies
- Portainer/Caddy log access paths.

## Risks
- High log volume.

## Open Questions
- Persist logs in DB or object storage?
