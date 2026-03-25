# Postgres Restore Plan

## Pillar
Data and backups

## Status
Partial

## Current Reality

- Backup creation and upload work.
- Operators can see backup status, retention, and schedule metadata.
- Backup artifacts are not yet tracked with a durable remote object path.
- Restore does not exist.
- Verification also does not exist, so the product can claim “backed up” without proving “recoverable.”

## Goal

Define the restore and verification model for Postgres so Conductor can move from backup creation to actual recovery confidence.

## Why This Plan Exists

`backups-r2.md` covers backup generation and storage. This plan covers the operationally harder half: downloading, restoring, verifying, and making restore actions safe enough for real use.

## Scope

- Restore workflow from stored backup artifact to selected target
- Restore safety model and confirmation flow
- Verification and test-restore strategy
- Restore state tracking and audit trail
- Integration with dashboard issues and backup trust indicators

## Non-goals

- Point-in-time recovery in the first pass
- Full high-availability cluster failover automation
- Supporting every database engine in the first implementation
- Hiding the operational risk of restore behind a one-click toy flow
- Automatic recurring restore drills in the first pass

## Restore Principles

1. A restore is a high-risk action and must be explicit.
2. Backup success is not enough; restore readiness must be visible.
3. Production restore and test restore are different workflows.
4. Operators need clear target, source, and consequence before execution.
5. A restore cannot run unless the backup artifact can be identified unambiguously.

## Restore Targets

At minimum, the model should distinguish:

### Test restore target

Used for verification or drills.

For v1, this should be a temporary database on the same host as the restore target, using a generated name such as `<database>_verify_<timestamp>`. Conductor should create it, verify it, then drop it after the check completes.

### Replacement restore target

Used to overwrite or replace an existing environment.

### Side-by-side restore target

Used to restore into a separate database for inspection or controlled cutover.

The first shipped path should prefer test restore and side-by-side restore before destructive replacement restore.

## Core Workflow 1: Test Restore for Verification

1. Select a backup artifact.
2. Confirm the backup has a durable artifact key or remote path.
3. Download the artifact to temporary storage on the target server.
4. Restore into a controlled test target.
5. Validate restore success with a minimal verification checklist.
6. Clean up temporary files and temporary verification database.
7. Record backup as verified with timestamp and verification result.

## Core Workflow 2: Side-by-Side Restore

1. Select source backup.
2. Select target host and target database name.
3. Validate target does not conflict with active production names by checking existing databases on the target host.
4. Download the artifact to temporary storage on the target server.
5. Run restore.
6. Record output, timing, and result.
7. Surface the restored target for operator follow-up.
8. Clean up temporary restore files.

## Core Workflow 3: Replacement Restore

1. Require explicit operator confirmation and context.
2. Confirm environment, host, and target DB identity.
3. Require the operator to type the target database name before execution.
4. Confirm the operator understands overwrite impact.
5. Download the artifact to temporary storage on the target server.
6. Run restore with strong audit trail.
7. Record success or failure in a durable restore run record.
8. Clean up temporary restore files.

This should ship only after the safer flows above are understood.

## Verification Definition

A backup should not count as “verified” merely because the file exists.

Minimum verification signals:

- artifact can be fetched
- artifact can be decompressed
- restore command completes successfully
- target database is queryable

Optional later verification:

- expected tables exist
- migration version is readable
- app-specific smoke checks run

## Artifact Fetch Path

For v1, Conductor should fetch restore artifacts on the target server over SSH, matching the existing upload model.

Recommended first-pass flow:

1. Open SSH connection to target host.
2. Download artifact from object storage to `/tmp/<artifact-name>` on that host.
3. Run restore locally on the same host against the selected Postgres target.
4. Remove temporary artifact after success or failure.

This avoids routing large artifacts through Conductor itself and keeps restore traffic local to the target host.

## Dump Format and Restore Command

The current backup flow produces a plain SQL dump compressed with `gzip`, not a custom `pg_restore` archive.

That means the v1 restore path must use `psql`, not `pg_restore`.

Recommended first-pass command shape:

```bash
gunzip -c /tmp/restore.sql.gz | psql "$DATABASE_URL"
```

If Conductor later adds custom-format dumps, the plan can expand to support `pg_restore` as a separate path. The initial restore implementation should match the dump format that exists today.

## Restore State Model

Recommended restore states:

- pending
- fetching_artifact
- restoring
- verifying
- completed
- failed
- cancelled

Each restore run should record:

- source backup id
- target type
- target host
- target database
- started at
- completed at
- initiated by
- failure summary

## Safety Rules

1. Default path should not be destructive.
2. Replacement restore must require stronger confirmation than test restore.
3. Restore actions must be auditable.
4. Restore failures must not silently corrupt backup trust indicators.
5. Backup verification should never be implied if restore has never been exercised.
6. Replacement restore must require typed confirmation of the target database name.

## Artifact Handling

For v1:

- artifacts are fetched from R2/S3-compatible storage onto the target server over SSH
- temporary local storage on the target server is the default path
- temporary artifact files must be deleted after success or failure
- temporary verification databases must be dropped after test restore completes
- side-by-side restore databases remain until the operator removes them
- encrypted-backup handling is deferred until backup encryption exists

## Failure Modes

### Fetch failure

- missing object
- invalid credential
- network timeout

### Restore failure

- incompatible target
- insufficient disk
- invalid dump artifact
- permissions mismatch

### Verification failure

- restore completed but target DB is unusable
- expected tables or metadata missing

Conductor should distinguish these clearly. “Could not fetch” is not the same as “restore failed after fetch.”

## Data Model Implications

Likely additions:

- restore run model
- verification status on backup records
- verified at
- verification target metadata
- artifact key or remote path on backup records
- restore error fields
- temporary target metadata for test restores

## Dependencies

- `docs/plans/backups-r2.md`
- backup artifact tracking from `docs/plans/backups-r2.md`
- operational visibility from `docs/plans/monitoring-ops.md`
- recurring scheduling context from `docs/plans/recurring-ops-schedule.md`

## Service and Job Boundaries

This work should not be folded into `DatabaseBackup`.

Recommended first-pass structure:

- `DatabaseRestore` service owns fetch, restore, verification, and cleanup orchestration
- `RestoreJob` runs restore workflows asynchronously
- restore run records hold progress and results for UI and audit purposes

This keeps backup creation and restore execution separate, which is important because their state models and safety expectations are different.

## Milestones

1. Define restore targets and safety model.
2. Add artifact key or remote path tracking to backup records.
3. Define artifact fetch and restore execution path.
4. Add restore run records and audit trail.
5. Add test-restore verification workflow.
6. Add side-by-side restore support.
7. Revisit destructive replacement restore after safer flows exist.

## Acceptance Checks

- Operators can verify a backup through an actual restore path.
- Restore runs record enough context to debug failures.
- Backup trust indicators distinguish uploaded vs verified backups.
- Destructive restore is harder to trigger than test restore.

## Future Integration Notes

- Automated recurring restore drills should come later, after the manual verification path is stable.
- Alerting on repeated restore verification failures should plug into the existing issue and notification model.
- If backup encryption is added later, the restore path must gain decrypt-before-restore handling.

## Decisions

- Use temporary local storage on the target server for v1, not streaming.
- Minimum “verified” status means the artifact was fetched, decompressed, restored, and the target DB answered a query.
- The safest first shipped restore path is a temporary verification database on the same target host.
- Encrypted backup handling is not applicable in v1 because client-side backup encryption is deferred.
