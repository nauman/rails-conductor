# Active Storage Plan

## Pillar
Data and backups

## Status
Partial

## Current Reality

- Active Storage visibility is part of the product vision but not a complete operational feature.
- The main unbuilt areas are collection strategy, cleanup workflow, and safe purge behavior.
- The older wording assumes an agent path that no longer matches the SSH-first direction.

## Goal

Give operators visibility into Active Storage footprint per app and safe tools to identify and run cleanup work.

## Scope

- Blob and storage usage summaries per app
- Recent upload activity and storage pressure indicators
- Cleanup candidate identification
- Safe purge and cleanup workflows with confirmation and audit trail

## Non-goals

- Cross-cloud storage migration in v1
- Full object-storage lifecycle management for every app
- Deep media analytics or content inspection

## Core Workflows

1. Inspect which apps are using the most Active Storage.
2. Identify stale blobs or cleanup candidates.
3. Run a safe cleanup workflow with confirmation.
4. Understand when storage growth becomes an operational issue.

## Requirements

1. Collect blob counts, size, and recency data in a way that fits app boundaries.
2. Keep cleanup actions explicit, auditable, and hard to trigger accidentally.
3. Connect storage pressure to operational views and issue reporting.
4. Avoid assumptions about agents; collection should work with current app architecture.
5. Separate visibility from destructive cleanup actions.

## Dependencies

- `docs/plans/monitoring-ops.md`
- app-level data collection strategy
- storage and backup visibility where relevant

## Milestones

1. Define data collection path for blob metrics.
2. Add storage summaries and per-app breakdowns.
3. Define cleanup candidate logic.
4. Add purge and cleanup workflow with confirmations and audit history.

## Risks

- Heavy blob queries can hurt app databases.
- Cleanup workflows can destroy data if safety rails are weak.
- Different apps may expose Active Storage state differently.

## Open Questions

- Query each app DB directly or gather metrics through an app-side endpoint?
- What qualifies as a cleanup candidate vs an operator review item?
- Should purge actions run inside the managed app context or from Conductor directly?
