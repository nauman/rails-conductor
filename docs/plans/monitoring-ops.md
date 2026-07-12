# Monitoring & Ops Plan

## Pillar
Fleet control

## Status
Partially implemented

## Current Reality

- Fleet dashboard exists and shows real server/app/backup state.
- Server metrics collection works over SSH.
- Critical issue detection exists for offline servers, failed deploys, and failed backups.
- Recurring collection exists, but the dashboard still conflates desired app
  state, observed container state, monitoring failures, and deploy failures.
- Lazy Solid Queue badges currently fail as missing Turbo Frame content on the
  overview.
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
6. Keep desired state, observed runtime state, monitoring freshness, and deploy
   state distinct in both data flow and labels.
7. Treat only actionable mismatches and observation failures as incidents;
   intentionally stopped apps are not incidents.

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
7. Repair the overview's lazy Turbo content, responsive navigation, action
   labels, and clipped content.
8. Add an incident-first queue above the full fleet inventory.

## Operational Dashboard Health Design

The overview combines three layers through progressive disclosure:

1. **Active incidents** — a compact queue of actionable mismatches and failed
   observations, ordered by severity.
2. **Fleet status** — the complete server-grouped inventory, including healthy,
   intentionally stopped, stale, unknown, and unsupported apps.
3. **Deep views** — app, logs, jobs, deployment, and server pages for diagnosis.

Do not build three separate dashboards. Repair the existing overview and make
the incident queue its high-signal entry point.

### State model

| Dimension | Values | Meaning |
| --- | --- | --- |
| Desired app state | running, stopped | What the operator expects |
| Observed runtime state | running, exited, dead, restarting, paused, unknown | What Docker last reported |
| Monitoring state | fresh, stale, failed, never checked, unavailable, unsupported | Whether the observation can be trusted |
| Deployment state | pending, running, succeeded, failed | The release workflow, separate from runtime health |

`App.status` currently combines operator intent and deployment lifecycle. For
this slice, `stopped` means desired stopped; `running`, `deploying`, and `failed`
all mean desired running. The latter two retain their deployment meaning and do
not overwrite observed runtime state. Separating desired state into its own
column is follow-up model work, not required for this dashboard repair.

Existing `container_status`, `last_status_check_at`, and `status_check_error`
remain the observed and monitoring inputs. Do not add schema in this slice.

Monitoring state uses this precedence:

1. `unsupported` — runtime is neither Docker nor Kamal; do not present cached
   container state as current.
2. `unavailable` — Docker/Kamal app has no server or usable SSH configuration.
3. `failed` — `status_check_error` is present, even when the failed attempt wrote
   a recent timestamp.
4. `never checked` — `last_status_check_at` is absent.
5. `stale` — last check is older than five minutes.
6. `fresh` — last check is within five minutes and has no error.

Docker and Kamal share this monitoring contract. Native runtime monitoring is
explicitly unsupported until native `systemctl` health collection lands.

### Incident rules

- Desired running + observed exited/dead/paused is critical and actionable.
- Desired running + observed running/restarting with fresh monitoring is healthy
  and omitted. Restarting remains visible in the fleet row.
- Desired running + observed unknown is warning (`Runtime not observed`) with
  Sync as the primary action.
- Desired running + monitoring failed/stale/never checked/unavailable is warning
  because health is not known; its monitoring label overrides any cached
  observed state.
- Desired running + unsupported monitoring is omitted because native health is
  outside this slice; the fleet row states `Unsupported · not checked`.
- Desired stopped + observed exited/dead/paused is healthy and omitted from
  Active incidents.
- Desired stopped + observed running/restarting under fresh monitoring is a
  warning mismatch (`Running unexpectedly`) with Stop or app details as the
  primary action.
- Desired stopped + observed unknown or non-fresh monitoring is omitted: a
  stopped app does not create monitoring noise until Conductor has trustworthy
  evidence that it is running.
- Desired stopped + unsupported monitoring is omitted and labelled unsupported
  in the fleet row.
- A failed deployment remains a deployment incident; it does not rewrite the
  observed container state.
- Unknown or stale observations must never be worded as "app is stopped."
- Runtime mismatch and monitoring facts about the same app collapse into one
  app incident. Critical mismatch wins over warning monitoring state; otherwise
  monitoring state supplies severity and Sync is the primary action. A failed
  deployment remains a separate deployment incident because it is a distinct
  event with its own drill-down.

### Fleet row contract

Each row shows:

- app and server identity
- desired state
- observed container state
- monitoring label and last-check age
- concise failure detail when observation failed
- distinct, visibly labelled actions: Sync, Logs, and Restart

The controller-level restart contract supports Docker, Kamal, and native apps
with a server and usable SSH. The container-monitoring dashboard exposes Restart
only for Docker or Kamal apps satisfying that controller-level contract. Native
restart remains available from the app detail workflow. Restart requires
confirmation and must not reuse the Sync icon or accessible label. Unknown and
failed monitoring rows lead with Sync; runtime mismatches lead with Logs or
Restart.

Unsupported apps display `Unsupported · not checked` and suppress cached
container state from the primary status label. Unavailable apps display the
reason (`No server` or `SSH unavailable`) and may show their last observation as
explicitly untrusted historical context.

The jobs badge remains lazy. A request for the app's canonical
`app_jobs_<id>` Turbo Frame returns the badge wrapped in that exact frame. A
normal HTML request renders the full jobs page. An unexpected Turbo Frame ID
returns the full page rather than a frameless empty response. Unavailable Solid
Queue data renders as "No job data," not Turbo's "Content missing" fallback.

### Responsive behavior

- `app/views/layouts/application.html.erb` owns the primary navigation repair.
  At widths below `lg` (1024 px), account email is hidden and the nav remains a
  horizontally scrollable region contained between the logo and account
  controls; no account control may extend beyond the viewport.
- The fixed/sticky header must not obscure section headings when scrolling.
- At the `sm` breakpoint (640 px), fleet rows stack metadata and labelled actions
  below app identity; the page has no horizontal overflow at 390 px.
- The four summary values use two columns below 640 px and four at 640 px and
  above.

### Error handling

- Show a short operator-facing reason for failed checks and keep raw diagnostic
  detail available on the app page.
- Keep stale and failed observation labels visible even when the last observed
  container state was running.
- Sync and restart enqueue work and return immediate feedback; destructive or
  disruptive actions require confirmation.

### Acceptance criteria

- [x] No overview row renders Turbo's "Content missing" fallback.
- [x] Intentionally stopped apps do not appear in Active incidents unless a
      fresh observation proves they are running or restarting.
- [x] Unknown, stale, and failed observations never claim an app is stopped.
- [x] Desired/observed mismatches produce one actionable incident per app.
- [x] Sync, Logs, and Restart have distinct visible labels and accessible names.
- [x] Every fleet row includes monitoring context: a last-check age for fresh,
      stale, or failed checks; `Never checked`; an unavailable reason; or
      `Unsupported · not checked`.
- [x] At 390 px and 1024 px viewport widths, account controls remain visible,
      headings are not obscured, and the page has no horizontal overflow.
- [x] Controller/model and integration tests cover the state matrix, Turbo Frame
      response, action confirmation, and responsive class contract; browser
      verification at 390 px and 1024 px proves actual reflow and containment.

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
