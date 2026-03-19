# Monitoring & Ops Plan

## Pillar
Fleet control

## Status
Implemented

## Current Reality

- Fleet dashboard exists and shows real server/app/backup state.
- Server metrics collection works over SSH.
- Critical issue detection exists for offline servers, failed deploys, and failed backups.
- The largest gap is not the dashboard itself, but the lack of recurring scheduling and historical depth.
- Operational freshness is now tracked explicitly in `docs/plans/recurring-ops-schedule.md`.

## Goal

Provide the operator’s main control view for host health, app status, deployments, and operational issues across the fleet.

## Scope

- Fleet summary cards and issue aggregation
- VM health snapshots: CPU, memory, disk, uptime
- App and deployment status visibility
- Backup visibility in operational views
- Drill-down paths from issue to next action

## Non-goals

- Full time-series observability platform in v1
- Deep APM or request-tracing features
- Replacing specialized analytics tools

## Core Workflows

1. Open the dashboard and see the health of the fleet quickly.
2. Identify degraded servers, failed deploys, and backup problems.
3. Drill into one server or app and decide the next action.
4. Use the dashboard as the main operator surface rather than multiple ad hoc admin pages.

## Requirements

1. Keep server, app, deployment, and backup state visible from one dashboard.
2. Surface issues with severity and action context, not just raw metrics.
3. Keep fleet state fresh enough to support operational decisions.
4. Support both server-centric and app-centric troubleshooting views.
5. Feed future notifications and trend views from the same issue model.

## Dependencies

- `docs/plans/logs-observability.md`
- `docs/plans/recurring-ops-schedule.md`
- recurring job scheduling in `config/recurring.yml`
- metric and status collection services already present in the app

## Milestones

1. Keep the existing dashboard as the foundation.
2. Add recurring schedule coverage for metrics and status refresh through `recurring-ops-schedule.md`.
3. Add stale-data issue types and freshness-aware issue detection.
4. Add app-centric drill-down view in addition to the current server-grouped view.
5. Add future issue sources from route, domain, and certificate state.
6. Add trend and history hooks where needed for later maintenance work.

## Existing Severity Model

The dashboard already uses a simple severity model:

- `critical`
- `warning`
- `info`

That severity ordering should remain the foundation for future issue sources.

Recommended interpretation:

- offline servers and failed deploys remain `critical`
- high CPU, high disk, and stale operational data are `warning`
- informational app states such as intentionally stopped apps remain `info`

## Freshness and Stale Data

Metric-based issue detection is only trustworthy when the underlying data is fresh.

This means monitoring should add stale-data issue types such as:

- stale server metrics
- stale container status
- overdue scheduled backup dispatch
- repeated recurring job failure

It also means metric-derived warnings should not pretend stale values are current. The monitoring layer should either suppress stale metric-based warnings or pair them with explicit stale-data warnings.

## Current View Gap

The existing dashboard is stronger on server-centric visibility than app-centric operational drill-down.

Current strength:

- apps grouped by server
- server fleet visibility
- recent deployments and backups

Current gap:

- no dedicated app-centric operational view that combines app health, deploys, server state, routing, domains, and backups in one place

That gap belongs to this plan, not only to app-specific screens.

## Future Issue Sources

As routing and domain work lands, the monitoring issue model should expand to include:

- route drift
- DNS verification failure
- certificate expiry warning
- route publication failure

These should extend the same issue aggregation model rather than create a separate monitoring silo.

## Risks

- Polling load may grow with fleet size.
- Freshness gaps can make a working dashboard feel unreliable.
- Without clear issue prioritization, operators may still fall back to SSH.

## Decisions

### Auto-refresh

Use lightweight page-level refresh or Turbo-driven refresh in v1 rather than a dedicated real-time dashboard socket model.

### Issue priority

Use the current severity ordering as the default:

- critical first
- warning second
- info last

Stale-data issues should default to warning severity.

### Timeline or events view

Defer a dedicated timeline/events view until historical metrics and trend work begins.
