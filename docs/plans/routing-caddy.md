# Routing (Caddy) Plan

## Goal
Manage global routing via Caddy Admin API and keep routes in sync with app environments.

## Scope
- Read and diff Caddy config.
- Add/remove host routes per deployment.
- Validate upstream health.

## Non-goals
- Multi-region edge routing in v1.

## Milestones
1. Store Caddy API endpoint + credentials.
2. Build route sync job (desired vs actual).
3. UI for domain → upstream mapping.

## Dependencies
- Global Caddy deployment.
- DNS automation for domains.

## Risks
- Config conflicts if multiple writers.
- Route drift if manual edits occur.

## Open Questions
- Should Conductor be the sole writer?
- How to snapshot configs for rollback?
