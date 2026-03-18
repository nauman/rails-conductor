# Active Storage Plan

## Goal
Track Active Storage usage, blob counts, and cleanup status per app.

## Scope
- Aggregate usage and blob counts.
- Surface last upload timestamps.
- Provide cleanup/purge actions.

## Non-goals
- Cross-cloud storage migration in v1.

## Milestones
1. Storage stats collection job.
2. Dashboard summary and per-app breakdown.
3. Purge/cleanup workflow with confirmations.

## Dependencies
- Direct DB access to blobs or app-level metrics endpoint.

## Risks
- Heavy queries on large blob tables.

## Open Questions
- Do we query each app DB or collect metrics via agent?
