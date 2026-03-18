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
- recurring job scheduling in `config/recurring.yml`
- metric and status collection services already present in the app

## Milestones

1. Keep the existing dashboard as the foundation.
2. Add recurring schedule coverage for metrics and status refresh.
3. Improve issue surfacing and drill-down paths.
4. Add trend and history hooks where needed for later maintenance work.

## Risks

- Polling load may grow with fleet size.
- Freshness gaps can make a working dashboard feel unreliable.
- Without clear issue prioritization, operators may still fall back to SSH.

## Open Questions

- How much auto-refresh belongs in the dashboard vs manual refresh?
- Which issue types should show first by default?
- When does the dashboard need a dedicated events/timeline view?
