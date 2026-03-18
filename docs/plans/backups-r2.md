# Backups (R2) Plan

## Goal
Automate Postgres and file backups to Cloudflare R2 with retention and restore.

## Scope
- Scheduled pg_dump per app environment.
- Upload to R2 with retention policies.
- Backup status reporting in dashboard.

## Non-goals
- Point-in-time recovery in v1.

## Milestones
1. R2 credentials and bucket setup UI.
2. Backup job runner + upload.
3. Retention cleanup + status reports.

## Dependencies
- R2 API access and IAM policies.
- Host-level job scheduling.

## Risks
- Large upload times and failure handling.

## Open Questions
- Centralized backup runner vs per-host cron?
- Encrypt backups before upload?
