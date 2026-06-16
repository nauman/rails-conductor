# Scheduled Jobs (Cron) Plan

## Pillar
Continuous maintenance

## Status
Planned (spec).

## Current Reality

- Conductor runs its OWN recurring work via Solid Queue (`config/recurring.yml`).
- It cannot yet manage **cron jobs on the servers it manages** — installing a scheduled command into a host's crontab is manual SSH today.
- It already manages a host resource via a "managed block" pattern (`CaddyClient` owns Conductor-tagged Caddy routes); the same idea fits crontab.

## Goal

A **cron-job creator UI**: define a scheduled command (frequency + command + server) in Conductor, and Conductor installs it into the server's crontab — Hatchbox-style. Human-friendly schedules ("every 2 hours", "daily at 3am") are translated to cron syntax via the `whenever` gem's expression builder.

## Scope

- `CronJob` model — `server`, `name`, `command`, `schedule` (human or cron), `status`, org-scoped.
- `CrontabClient` — reads/writes a **Conductor-managed crontab block** over SSH (mirrors `CaddyClient`): markers like `# >>> conductor:<id>` … `# <<< conductor:<id>` so we only touch our own entries.
- Schedule translation — `whenever` (or `fugit`) turns "every 2 hours" into `0 */2 * * *`; allow raw cron too.
- UI — list/create/enable/disable/delete cron jobs on a server; show next-run and last output (best-effort).

## Non-goals

- A distributed scheduler — these are plain crontab entries on one host.
- Replacing Conductor's internal Solid Queue recurring jobs.
- Per-second precision / sub-cron granularity.

## Core Workflows

1. **Create** — pick a server, name it, enter a command + a friendly schedule → Conductor writes a managed crontab entry over SSH.
2. **List/toggle** — see managed jobs for a server; enable/disable (comment/uncomment) or delete (managed block only).
3. **Verify** — read back the managed block to confirm; never touch non-Conductor crontab lines.

## Data Model

```
CronJob
 ├── organization, server
 ├── name, command, schedule (e.g. "every 2 hours" or "0 */2 * * *")
 ├── cron_expression (resolved)
 └── status (enabled | disabled)
```

## Verification (test-first)

- `CrontabClient#upsert_job` writes only the `# >>> conductor:<id>` … `# <<< conductor:<id>` block, preserving other lines (tested with a fake SSH connection, like `CaddyClient`/`PostgresClusterClient`).
- Friendly schedule → cron expression mapping (via whenever) is unit-tested.
- Removing a job deletes only its managed block.

## Slices

1. **Model + CrontabClient** — managed-block read/write over SSH; schedule→cron. (test-first)
2. **UI** — cron jobs per server: create/list/toggle/delete.
3. **Built-in jobs** — offer the `server-audit` / `server-auto-update` maintenance scripts as one-click scheduled jobs.

## Related

The three **maintenance scripts** (`server-harden`, `server-auto-update`, `server-audit`) are already built-in Conductor Scripts (`db/seeds.rb`) — slice 3 here lets them be *scheduled*. See `docs/learnings/multi-app-hosting.md`.
