# Recurring Ops Schedule Plan

## Pillar
Continuous maintenance

## Status
Partial

## Current Reality

- The core jobs already exist for metrics refresh, container status sync, and scheduled backup dispatch.
- `config/recurring.yml` only schedules queue cleanup.
- `config/recurring.yml` currently only has a `production:` block, which makes local schedule testing awkward.
- The dashboard and issue model depend on fresh data, but the product does not continuously collect it yet.
- `RefreshServerMetricsJob` fans out into one SSH-backed job per server.
- `SyncContainerStatusJob` fans out into one SSH-backed job per app and currently only covers Docker/container status, not native `systemctl` health.

## Goal

Turn existing background jobs into a reliable recurring operations schedule so Conductor behaves like a continuous control plane instead of a mostly manual dashboard.

## Scope

- Recurring scheduling for metrics, container sync, and scheduled backup dispatch
- Environment coverage for recurring schedule definitions
- Job cadence definitions and ownership per job
- Queue isolation and concurrency expectations for SSH-heavy jobs
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
5. Developers can validate recurring-job behavior locally without waiting for production-only execution.

## Requirements

1. Add recurring entries for `RefreshServerMetricsJob`, `SyncContainerStatusJob`, and `RunScheduledBackupsJob`.
2. Define whether recurring entries live in both `development:` and `production:` blocks, with development enabled for local testing from the start.
3. Define target cadence for each job with practical load assumptions and explicit fan-out awareness.
4. Specify queue isolation for recurring orchestration so backup-related work does not starve freshness-related work.
5. Expose freshness or last-run state where operators can see it, with a concrete definition per job type.
6. Record and surface recurring-job failures so stale data is visible, not silent.
7. Keep the schedule easy to extend for future checks such as native service status or certificate monitoring.

## Dependencies

- `config/recurring.yml`
- `app/jobs/refresh_server_metrics_job.rb`
- `app/jobs/sync_container_status_job.rb`
- `app/jobs/run_scheduled_backups_job.rb`
- `docs/plans/monitoring-ops.md`

## Milestones

1. Add initial recurring schedule entries for metrics, container sync, and backup dispatch in both development and production.
2. Define queue isolation and concurrency expectations for SSH-heavy recurring work.
3. Define freshness expectations and dashboard indicators for stale operational data.
4. Add failure visibility for recurring jobs.
5. Extend the schedule to native-service health checks and other continuous ops work.

## Suggested Initial Cadence

- Metrics refresh: every 5 minutes
- Container sync: every 2 minutes
- Scheduled backup dispatch: every 1 minute

## Environment Coverage

The first implementation should define recurring schedules in:

- `development:` so the team can validate cadence, failure behavior, and fan-out locally
- `production:` so the live product runs continuously

There is no product value in making recurring scheduling production-only during the first pass because the main risks are operational correctness and load behavior, both of which need local verification.

## Queue and Concurrency Model

The current jobs all use `queue_as :default`. That is acceptable as a code baseline but should not be treated as the final operating model for recurring work.

### Why queue isolation is needed

- metrics refresh fans out into one job per server
- container sync fans out into one job per app
- backup dispatch can enqueue expensive backup work

Without isolation, heavy backup activity can delay metrics and container freshness, which makes the dashboard look healthier or newer than it really is.

### First-pass queue intent

- recurring orchestration should run in a dedicated queue such as `ops`
- fan-out child jobs that perform SSH-backed freshness work should also run on `ops` or a dedicated `ssh` queue, not fall back to `default`
- expensive child work such as actual backup execution may remain separate from orchestration
- queue concurrency should be chosen to avoid opening too many simultaneous SSH sessions

### Concurrency concerns to resolve in implementation

- how many SSH-backed jobs may run at once
- whether fan-out jobs need staggering or jitter
- whether unreachable hosts should fail fast after bounded timeout rather than tying up workers

This plan does not solve those with exact numbers yet, but it must require that implementation chooses and documents them explicitly.

## Fan-out and Load Model

The scheduler is cheap; the fan-out jobs are not.

Example:

- 10 servers on metrics refresh means 10 SSH-backed child jobs every cycle
- 20 apps on container sync means 20 SSH-backed child jobs every cycle

That makes recurring orchestration an SSH-load problem, not just a schedule problem.

The implementation should therefore assume:

1. parent recurring jobs enqueue child jobs, not do all network work inline
2. SSH timeouts must be bounded
3. queue concurrency must be constrained
4. future staggering/jitter may be needed if fleet size grows

## Known Blind Spots

### Native app status

`SyncContainerStatusJob` only covers Docker-backed app status. Native/systemd apps are not included in this freshness loop yet.

This is intentional for now and should be treated as a known gap, not an unnoticed omission.

Native `systemctl` health checks should join the recurring schedule when native deploy completion lands under the runtime-backend/routing work.

### Uptime accuracy

`Server#formatted_uptime` currently derives from `created_at`, which reflects when the server was added to Conductor rather than true machine uptime.

This plan should note that recurring metrics collection is also the right place to capture actual uptime from the host so dashboard uptime becomes operationally correct later.

### Offline transition behavior

`RefreshServerMetricsJob` calls `server.mark_offline!` on connection-style failures. That method only sends an offline alert on the first transition into offline state.

That behavior is intentional and should remain so recurring jobs do not spam duplicate offline alerts on every failed cycle.

## Freshness Definitions

Freshness must be explicit per recurring data type.

### Server metrics freshness

- source: `metrics_updated_at`
- current baseline: fresh if updated within 5 minutes
- operator surfacing: stale metrics should appear as a dashboard issue

### Container status freshness

- source: `last_status_check_at`
- required addition: define a freshness helper or equivalent dashboard rule
- baseline target: fresh if updated within a small multiple of the sync cadence
- operator surfacing: stale container state should appear as a dashboard issue

### Backup scheduler freshness

- source: successful execution of scheduled-backup dispatch and resulting backup run state
- meaning: scheduled backups are being dispatched when due, not silently skipped
- operator surfacing: overdue or undispatched scheduled backups should appear as a dashboard issue

## Failure Surfacing

Recurring failure must be visible in operator workflows, not only in job tables.

### First-pass failure surfacing requirements

1. dashboard should show stale-data issue types when freshness falls behind
2. repeated recurring-job failure should become visible through issue aggregation
3. Solid Queue failure records may be used as a source, but operator-facing issue types should not depend on users reading queue internals

### Recommended first issue types

- stale server metrics
- stale container status
- overdue scheduled backup dispatch
- repeated recurring job failure

### Notification stance

Do not add new alert channels in this plan. Email escalation for repeated recurring failures can come later, but the plan should require dashboard-visible failure state immediately.

## Risks

- Overly aggressive schedules can create avoidable SSH load.
- Silent recurring-job failure makes the dashboard look healthier than reality.
- Different job cadences can create confusing freshness gaps across the product.
- Default-queue contention can starve freshness work behind heavier jobs.

## Decisions

### Fixed vs configurable cadence

Use fixed cadences first. Configurability is premature until the baseline operating load is understood.

### Where freshness should surface

Dashboard first. Add stale-data issue types through issue aggregation rather than requiring operators to inspect job internals.

### When native `systemctl` checks join

When native deploy completion lands. It is a known follow-on, not a blocker for scheduling the existing Docker-oriented jobs now.
