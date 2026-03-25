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

## Shipped Baseline

The current backup layer already does meaningful work and should be treated as a foundation, not a blank slate.

| Capability | Status | Implementation |
| --- | --- | --- |
| `pg_dump` to compressed file | Complete | dump command builds compressed DB backup artifact |
| Upload to R2 | Complete | current backup service uploads to R2-compatible storage |
| Upload to S3 | Complete | current backup service uploads to S3-compatible storage |
| Local backup path | Complete | backup artifact can remain on the server |
| Scheduling model | Complete | due backups are discovered and dispatched |
| Retention configuration | Complete | retention days exist on backup records |
| Failure alerting | Complete | backup failures trigger operator-facing alerts |
| Backup status tracking | Complete | backup records track run state |
| Backup size tracking | Complete | backup size is recorded after successful work |

The plan should preserve this baseline while fixing the trust gaps around restore-readiness, retention enforcement, and artifact tracking.

## Goal

Make backup operations trustworthy by covering creation, retention, restore, verification, and recovery visibility for database backups stored in R2-compatible storage.

## Scope

- Scheduled Postgres backups per app environment
- Upload to R2/S3-compatible storage
- Retention policies
- Backup status reporting in operational views
- Verification and recovery-readiness state

## Non-goals

- Point-in-time recovery in v1
- Becoming a full backup vendor with cross-region replication on day one
- Supporting every database engine in the first pass

## Core Workflows

1. Schedule backups and confirm they continue running.
2. See which backups are fresh, stale, failed, or unverified.
3. Enforce retention and keep stored artifacts aligned with backup records.
4. Verify backups periodically so operators trust recovery claims.

## Requirements

1. Keep backup schedule, freshness, size, retention, and status visible in the app.
2. Add verification or test-restore jobs so backup state is not just “uploaded”.
3. Track backup artifact location so later verification and restore can find the actual file.
4. Support R2-backed storage as a first-class destination while remaining S3-compatible.
5. Surface backup failures and stale backups through the fleet issue model.
6. Enforce retention against actual stored artifacts, not only backup rows.
7. Document current operational limitations and security tradeoffs in the existing upload path.

## Dependencies

- `docs/plans/cloudflare.md`
- `docs/plans/postgres-restore.md`
- recurring job scheduling
- operational views from `docs/plans/monitoring-ops.md`

## Milestones

1. Keep the current backup creation and upload flow as the baseline.
2. Add artifact tracking for uploaded backups.
3. Add retention enforcement and cleanup handling.
4. Add verification and restore-readiness state.
5. Add stronger failure handling and security cleanup notes for the upload path.

## Retention Enforcement

Retention is not complete until old artifacts are actually cleaned up.

The plan should assume:

1. expired backups are identified from backup completion time plus retention policy
2. cleanup must target remote storage artifacts, not only local database rows
3. cloud deletion failure must not silently remove the backup record
4. cleanup should run through a scheduled job rather than ad hoc operator action

Retention configuration without enforcement is only metadata.

## Artifact Tracking

Backup records need to know where the uploaded artifact lives.

Minimum artifact-tracking expectation:

- persist the remote key or remote path for uploaded artifacts
- preserve enough metadata for later verification and restore download

This is a prerequisite for the restore plan because Conductor cannot restore what it cannot identify.

## Current Operational Limitations

### Database connection assumption

The current backup approach assumes `DATABASE_URL` is available in the execution environment.

That is fragile because:

- multi-app hosts may have multiple databases
- environment source may differ by deploy style
- database credentials may not exist as one globally available shell variable

The plan should therefore treat explicit database connection configuration as a future hardening requirement rather than assuming one ambient variable is always correct.

### Credential exposure in CLI calls

The current upload approach passes provider credentials into shell execution in a way that may be visible to process inspection on the host.

That is an accepted v1 risk, not an ideal end state.

Future hardening can move toward safer credential delivery or SDK-driven uploads, but this plan should document the current tradeoff rather than hide it.

### R2 endpoint/account mapping concern

The current R2 upload path should be reviewed for correctness around account identifier vs secret usage when constructing the endpoint and authentication values.

This plan should treat that as a correctness check to resolve, not assume the current path is perfectly modeled.

### Backblaze B2 support gap

If Backblaze B2 is exposed as a backup provider at the model level but not fully supported in the upload path, the product state is inconsistent.

This plan should therefore require one of:

- implement B2 upload support
- remove B2 from the exposed provider set
- mark it explicitly unsupported until implemented

v1 should not pretend provider support exists when the execution path does not.

## Backup Freshness and Issue Sources

This plan should feed the monitoring and recurring-ops layers with concrete backup-trust signals.

Examples:

- overdue scheduled backup dispatch
- last successful backup older than expected for its schedule
- no successful backup ever for an enabled backup configuration
- unverified backup state despite successful upload

These are backup trust issues, not just backup storage facts.

## Risks

- Backup uploads can succeed while restores still fail.
- Large backups may create long upload windows and timeouts.
- Recovery UX can be dangerous if production targets are not explicit.
- Retention cleanup can create false confidence if remote deletion fails silently.

## Decisions

### Execution model

Use per-host execution in v1. Backup creation should run where the database is reachable rather than introducing a centralized runner first.

### Encryption before upload

Do not add client-side encryption in v1. Use the current storage path and revisit stronger encryption only after restore-readiness and artifact tracking are in place.

### Restore path ownership

Restore workflow belongs to `postgres-restore.md`. This plan owns backup trust and artifact lifecycle, not the restore UX itself.
