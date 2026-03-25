# Logs & Observability Plan

## Pillar
Continuous maintenance

## Status
Partial

## Current Reality

- Deploy logs and script output stream in real time via ActionCable.
- Deploy logs are already stored in `deployment.log`.
- Script run output is already stored in `script_run.stdout` / `script_run.stderr`.
- Docker app logs can already be fetched on demand via SSH.
- Native app logs can already be fetched on demand via SSH.
- There is no centralized operational log model across apps, servers, and routing.
- The older Portainer/agent assumption is too narrow for the current SSH-first vision.

## Existing Baseline

Current log access is not zero. It is uneven.

### Already built

- deploy output: stored and streamable
- script output: stored and streamable
- Docker app logs: fetched on demand
- native app logs: fetched on demand

### Not yet available

- Caddy log access
- broader system log access
- centralized runtime log storage

This means the plan should start from improving and extending the current retrieval model, not from inventing a full new logging subsystem.

## Goal

Give operators practical access to recent logs across apps, servers, Caddy, and maintenance workflows without requiring immediate SSH access.

## Scope

- Log access for Docker apps, native apps, Caddy, and provisioning/deploy flows
- Streaming for active operations
- Recent log retrieval for debugging after the fact
- Basic filtering by app, server, source, and time window
- Practical limits for fetch size and log volume

## Non-goals

- Full log analytics pipeline in v1
- Long-term SIEM-style retention and search
- Deep query language or arbitrary dashboards
- Centralized log storage layer in v1

## V1 Storage Decision

Use on-demand SSH log retrieval in v1. Do not build a new centralized runtime log storage layer yet.

Why:

- deploy and script logs are already stored where it matters
- runtime log retrieval already works for Docker and native apps
- log storage adds schema, retention, cleanup, and volume-management work that is not needed to unlock the next operational value

This means v1 focuses on:

- improving retrieval UX
- adding missing sources such as Caddy logs
- making existing retrieval paths easier to use

## Core Workflows

1. View live deploy or provisioning output.
2. Open recent app or server logs when an issue appears in the dashboard.
3. Filter logs by app, server, or source to debug the problem quickly.
4. Preserve enough recent history to support post-failure inspection.

## Source Inventory and Access Methods

The plan should make the runtime log sources explicit.

| Source | Access Method | V1 Storage |
| --- | --- | --- |
| Deploy output | Already stored on deployment records and streamed | Stored |
| Script output | Already stored on script run records and streamed | Stored |
| Docker app logs | SSH + `docker logs --tail N` | On demand only |
| Native app logs | SSH + `journalctl --user -u <service> --no-pager -n N` | On demand only |
| Caddy logs | SSH + `journalctl -u caddy --no-pager -n N` or equivalent | On demand only |

The first missing source to add is Caddy logs because routing work depends on being able to debug Caddy behavior.

## Requirements

1. Support log access without depending on Portainer or an agent.
2. Treat live streaming and recent retrieval as separate but connected workflows.
3. Support Docker, native Puma/systemd, and Caddy log sources.
4. Expose logs through the same operational model used by fleet issues.
5. Keep v1 runtime logs on-demand rather than introducing a storage layer.
6. Define filtering and fetch-size rules so log retrieval stays practical over SSH.

## Dependencies

- `docs/plans/monitoring-ops.md`
- `docs/plans/routing-caddy.md`
- `docs/plans/recurring-ops-schedule.md`
- runtime backend log source definitions

## Milestones

1. Treat the existing app log retrieval path as the baseline.
2. Add Caddy log retrieval.
3. Improve recent-log retrieval UI for Docker and native apps.
4. Add filtering by app, server, source, and time window.
5. Define fetch-size limits and truncation behavior.

## Existing App Log Retrieval

The current app log retrieval action is the right v1 foundation.

What exists now:

- Docker path uses `docker logs --tail ...`
- native path uses `journalctl --user -u ...`

What still needs improvement:

- better formatting in the UI
- clearer source selection
- optional time-window filtering
- alignment with issue-driven troubleshooting flows

## Filtering Model

Filtering should stay compatible with on-demand SSH access.

### By app

- start from the app context and fetch that app's runtime logs

### By server

- start from the server context and fetch logs for selected sources on that server

### By source

- operator selects Docker, native service, or Caddy source

### By time window

- pass source-appropriate options such as `--since` where supported

This is enough for v1 without introducing indexed storage.

## Fetch Size and Truncation

SSH log retrieval needs hard limits.

The plan should assume:

- a default tail size for runtime logs
- a maximum fetch size to avoid hanging on large output
- last-N-lines retrieval is sufficient for v1

Pagination and deep history browsing can wait until there is a stronger case for stored logs.

## Future Integration Points

### Recurring operations

This plan does not add recurring log scanning in v1, but it should leave room for later checks such as:

- repeated Caddy 502 errors
- repeated connection-refused patterns
- recurring service failure signatures

### Alerts and notifications

Log-derived alerts are a later integration point. They should extend the monitoring and notification system rather than create a parallel alert path inside the logs UI.

## Risks

- High log volume can overwhelm naive storage choices.
- Different runtime backends expose logs differently.
- Logging strategy can sprawl into analytics if not constrained.

## Decisions

### Storage model

Use on-demand SSH retrieval for v1. Do not add runtime log storage beyond what already exists for deploy and script output.

### Retention

Not applicable for v1 runtime logs because Conductor will not store them centrally. Retention only matters later if a storage layer is introduced.

### Source priority

Deploy and app runtime logs already exist. Add Caddy logs next. General system logs are lower priority.
