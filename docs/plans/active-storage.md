# Active Storage Plan

## Pillar
Data and backups

## Status
Deferred

## Current Reality

- Conductor does not currently have a safe, proven way to inspect Active Storage state inside managed apps.
- Current server metrics already provide coarse disk-pressure visibility without understanding app-level blob usage.
- The older wording assumes more access to managed app internals than the current SSH-first model actually has.
- Cleanup and purge are not built and should not be treated as near-term product commitments.

## Goal

Document the minimum honest stance for Active Storage in Conductor: server-level storage pressure is visible today, but per-app blob visibility and cleanup are deferred until the product has a justified and safe data-collection model.

## Why This Plan Exists

Active Storage is relevant because many Rails apps store user files in object storage, and those files affect operational cost and recovery confidence. But Conductor manages fleets from the outside. It does not automatically have direct, safe insight into another app's `active_storage_*` tables or blob lifecycle.

## Scope

- Define what Conductor can truthfully show today about storage pressure
- Capture the architectural options for deeper app-level Active Storage visibility
- Document why per-app blob inspection and cleanup are deferred
- Note the relationship between blob storage and backup trust

## Non-goals

- Cross-cloud storage migration in v1
- Full object-storage lifecycle management for every app
- Deep media analytics or content inspection
- Destructive cleanup or purge of managed app blobs in v1
- Assuming direct database access into every managed Rails app
- Requiring app-side agents or endpoints before the core control plane is stable

## Core Workflows

1. Understand when storage growth becomes an operational issue at the server level.
2. Decide whether deeper Active Storage visibility is worth adding for a specific managed app model.
3. Defer destructive cleanup until the collection and safety model is credible.

## Requirements

1. Be explicit that current visibility is coarse server-level disk pressure, not app-level blob analytics.
2. Treat per-app Active Storage inspection as an architectural decision, not an assumed capability.
3. Keep destructive cleanup out of v1 unless Conductor can prove safe app-specific context and auditability.
4. Acknowledge that database backups do not restore blob objects stored in R2/S3.
5. Separate storage visibility from destructive cleanup actions.

## Architectural Reality

Per-app Active Storage visibility would require one of two patterns:

1. Direct database access into the managed app's database
2. An app-side endpoint or integration that reports blob metrics back to Conductor

Both are substantially more invasive than the rest of the current Conductor architecture.

Direct database access would require:

- app-specific database credentials
- knowledge of the managed app's schema and Rails version
- network or SSH-tunneled database connectivity
- safe handling when Active Storage tables do not exist

App-side reporting would require:

- changes inside the managed app
- a stable integration contract
- version coordination across apps

Neither path is justified for the first control-plane milestones.

## Current Useful Visibility

Today, the practical storage signal Conductor can provide is:

- server disk usage and disk-pressure alerts from existing metrics collection
- object storage configuration visibility where Conductor already manages backups

That is weaker than true per-app Active Storage analytics, but it is honest and already aligned with the existing architecture.

## Backup Trust Implication

Active Storage also exposes a recovery gap:

- Postgres backups capture blob metadata
- they do not capture the blob files stored in R2/S3
- restoring the database alone does not fully restore uploaded files

This should be documented as part of Conductor's backup-trust story, even if Active Storage visibility remains deferred.

## Dependencies

- `docs/plans/monitoring-ops.md`
- `docs/plans/backups-r2.md`
- app-level data collection strategy if this work is ever revived

## Milestones

1. Reclassify this work as deferred until core routing, provider, and recovery work is further along.
2. Keep server-level disk pressure as the storage visibility baseline.
3. Revisit whether managed-app storage visibility has enough demand to justify a dedicated integration path.
4. Only after that, define whether the collection path is DB-based or app-reported.

## Risks

- Heavy blob queries can hurt app databases.
- Cleanup workflows can destroy data if safety rails are weak.
- Different apps may expose Active Storage state differently.
- This capability may be low-value relative to the architectural and operational risk required to build it.

## Decisions

- Conductor will not choose between direct DB access and app-side reporting in v1 because neither path is justified yet.
- Cleanup candidate logic is deferred because cleanup itself is out of scope for v1.
- Conductor should not purge managed-app blobs in v1.
