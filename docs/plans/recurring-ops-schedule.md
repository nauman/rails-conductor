# Recurring Ops Schedule Plan

## Pillar
Continuous maintenance

## Status
Partial

## Current Reality

- The core jobs already exist for metrics refresh, container status sync, and scheduled backup dispatch.
- `config/recurring.yml` only schedules queue cleanup.
- The dashboard and issue model depend on fresh data, but the product does not continuously collect it yet.

## Goal

Turn existing background jobs into a reliable recurring operations schedule so Conductor behaves like a continuous control plane instead of a mostly manual dashboard.

## Scope

- Recurring scheduling for metrics, container sync, and scheduled backup dispatch
- Job cadence definitions and ownership per job
- Failure handling, retries, and visibility for recurring jobs
- Operational freshness expectations for dashboard and issue detection
- Basic expansion path for future recurring checks

## Non-goals

- Building a new scheduler outside Solid Queue
- Solving every drift-detection or maintenance workflow in this plan
- Full trend analytics or maintenance windows in the first pass

## Core Workflows

1. Metrics refresh runs automatically and keeps server state current.
2. Container status sync runs automatically and keeps Docker app state current.
3. Scheduled backups are dispatched automatically without operator intervention.
4. Operators can tell whether recurring jobs are healthy, delayed, or failing.

## Requirements

1. Add recurring entries for `RefreshServerMetricsJob`, `SyncContainerStatusJob`, and `RunScheduledBackupsJob`.
2. Define target cadence for each job with practical load assumptions.
3. Expose job freshness or last-run state where operators can see it.
4. Record and surface recurring-job failures so stale data is visible, not silent.
5. Keep the schedule easy to extend for future checks such as native service status or certificate monitoring.

## Dependencies

- `config/recurring.yml`
- `app/jobs/refresh_server_metrics_job.rb`
- `app/jobs/sync_container_status_job.rb`
- `app/jobs/run_scheduled_backups_job.rb`
- `docs/plans/monitoring-ops.md`

## Milestones

1. Add initial recurring schedule entries for metrics, container sync, and backup dispatch.
2. Define freshness expectations and dashboard indicators for stale operational data.
3. Add failure visibility for recurring jobs.
4. Extend the schedule to native-service health checks and other continuous ops work.

## Suggested Initial Cadence

- Metrics refresh: every 5 minutes
- Container sync: every 2 minutes
- Scheduled backup dispatch: every 1 minute

## Risks

- Overly aggressive schedules can create avoidable SSH load.
- Silent recurring-job failure makes the dashboard look healthier than reality.
- Different job cadences can create confusing freshness gaps across the product.

## Open Questions

- Should cadences be globally fixed first or configurable per environment later?
- Where should operators see freshness and failure state: dashboard, job admin, or both?
- When should native `systemctl` health checks join the recurring schedule?
