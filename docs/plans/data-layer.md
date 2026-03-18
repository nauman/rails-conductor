# Data Layer Plan

## Goal
Define Postgres strategy for user apps and managed DB options.

## Scope
- Document shared cluster vs per-app DB containers.
- Backup/restore integration.
- DB credentials management.

## Non-goals
- Fully managed DB service in v1.

## Milestones
1. Choose baseline DB strategy for MVP.
2. Add DB provisioning workflow (manual first).
3. Integrate DB backup status into dashboard.

## Dependencies
- Host provisioning and storage capacity.

## Risks
- Multi-tenant performance contention.

## Open Questions
- Shared cluster with logical isolation vs dedicated containers?
