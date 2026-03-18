# Backups (R2) Plan

## Pillar
Data and backups

## Status
Partial

## Current Reality

- Postgres backups are created and uploaded successfully.
- Scheduling exists, but the broader backup trust model is incomplete.
- Restore does not exist.
- Verification, encryption policy, and richer recovery workflows are not defined.

## Goal

Make backup operations trustworthy by covering creation, retention, restore, verification, and recovery visibility for database backups stored in R2-compatible storage.

## Scope

- Scheduled Postgres backups per app environment
- Upload to R2/S3-compatible storage
- Retention policies
- Backup status reporting in operational views
- Restore workflows
- Verification and recovery-readiness state

## Non-goals

- Point-in-time recovery in v1
- Becoming a full backup vendor with cross-region replication on day one
- Supporting every database engine in the first pass

## Core Workflows

1. Schedule backups and confirm they continue running.
2. See which backups are fresh, stale, failed, or unverified.
3. Restore a selected backup into a target safely.
4. Verify backups periodically so operators trust recovery claims.

## Requirements

1. Keep backup schedule, freshness, size, retention, and status visible in the app.
2. Add restore flows with explicit target and audit trail.
3. Add verification or test-restore jobs so backup state is not just “uploaded”.
4. Support R2-backed storage as a first-class destination while remaining S3-compatible.
5. Surface backup failures and stale backups through the fleet issue model.

## Dependencies

- `docs/plans/cloudflare.md`
- recurring job scheduling
- operational views from `docs/plans/monitoring-ops.md`

## Milestones

1. Keep the current backup creation and upload flow as the baseline.
2. Add restore workflow design and implementation.
3. Add verification and restore-readiness state.
4. Add stronger retention, encryption, and failure handling rules.

## Risks

- Backup uploads can succeed while restores still fail.
- Large backups may create long upload windows and timeouts.
- Recovery UX can be dangerous if production targets are not explicit.

## Open Questions

- Centralized backup runner vs per-host execution?
- Encrypt backups before upload?
- What is the safest restore path for production environments?
