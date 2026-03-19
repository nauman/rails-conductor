# Postgres Restore Plan

## Pillar
Data and backups

## Status
Partial

## Current Reality

- Backup creation and upload work.
- Operators can see backup status, retention, and schedule metadata.
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

## Restore Principles

1. A restore is a high-risk action and must be explicit.
2. Backup success is not enough; restore readiness must be visible.
3. Production restore and test restore are different workflows.
4. Operators need clear target, source, and consequence before execution.

## Restore Targets

At minimum, the model should distinguish:

### Test restore target

Used for verification or drills.

### Replacement restore target

Used to overwrite or replace an existing environment.

### Side-by-side restore target

Used to restore into a separate database for inspection or controlled cutover.

The first shipped path should prefer test restore and side-by-side restore before destructive replacement restore.

## Core Workflow 1: Test Restore for Verification

1. Select a backup artifact.
2. Download or stream the artifact from storage.
3. Restore into a controlled test target.
4. Validate restore success with a minimal verification checklist.
5. Record backup as verified with timestamp and verification result.

## Core Workflow 2: Side-by-Side Restore

1. Select source backup.
2. Select target host and target database name.
3. Validate target does not conflict with active production names.
4. Run restore.
5. Record output, timing, and result.
6. Surface the restored target for operator follow-up.

## Core Workflow 3: Replacement Restore

1. Require explicit operator confirmation and context.
2. Confirm environment, host, and target DB identity.
3. Confirm the operator understands overwrite impact.
4. Run restore with strong audit trail.
5. Record success or failure in a durable restore run record.

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

## Artifact Handling

The plan must define:

- how artifacts are fetched from R2/S3-compatible storage
- whether they are restored via local temp storage or streaming
- cleanup of temporary files
- encryption handling if backup encryption is added

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
- verification status
- verified at
- verification target metadata
- restore error fields

## Dependencies

- `docs/plans/backups-r2.md`
- `docs/plans/cloudflare.md`
- storage artifact retrieval path
- operational visibility from `docs/plans/monitoring-ops.md`

## Milestones

1. Define restore targets and safety model.
2. Define artifact fetch and restore execution path.
3. Add test-restore verification workflow.
4. Add restore run records and audit trail.
5. Add side-by-side restore support.
6. Revisit destructive replacement restore after safer flows exist.

## Acceptance Checks

- Operators can verify a backup through an actual restore path.
- Restore runs record enough context to debug failures.
- Backup trust indicators distinguish uploaded vs verified backups.
- Destructive restore is harder to trigger than test restore.

## Open Questions

- Should restore use temp local storage, streaming, or both?
- What minimum verification makes a backup “verified” in the UI?
- What is the safest first shipped restore target?
- How should encrypted backups change the restore path later?
