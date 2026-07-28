# 08 — Operability gaps: schema state, resolving failures, easy backups, real schedules, job control

Status: **Spec — slice 1 shipped (`d65908c`), 2026-07-29.**

> Renumbered 07 → 08 on 2026-07-29. `07` in this series is
> `07-control-machine-build-and-ssh` (build on the control machine, push, target
> pulls — supersedes the SSH-roll patching), which was already being called "plan 07"
> in the threads before it landed in git. Same number, two documents, one series: the
> slot went to whoever named it first.
 Five gaps found by designing the app and
fleet pages against real fleet data, not by reading the code. Each one is small on its
own; together they're the difference between a control plane you glance at and one you
have to SSH behind.

Mockups: `conductor/design/app-overview.html`, `fleet.html`, `jobs.html` (kuickr).

## Why these five, and why now

Designing the pages forced honest questions, and the fleet answered badly:

| Question the page must answer | Today |
|---|---|
| Is my schema current? | **Nothing knows.** `db:migrate` runs at deploy, the answer is discarded |
| What's actually broken right now? | **Can't tell.** Failure state never resolves, so fixed problems still shout |
| Is my data safe? | **0 of 12 apps** have a backup, because setup asks for 4 fields |
| Did my nightly task run? | Only host-level cron exists — no app env, no history |
| A job failed. Now what? | Counts are shown; **no retry, no discard** — you SSH |

None of this is exotic. Heroku answers all five, and four of them are things Conductor
already half-has.

## 1. Failure state must resolve itself  (S · highest ratio of value to effort)

**Problem.** A deploy that failed stays failed forever in the UI, even after the next
deploy fixes it. This week: **11 failures, 8 already superseded, 3 genuinely broken** —
but the fleet reads as "11 problems", so the operator learns to ignore the signal. Worse,
Conductor's own row says "failed, Jul 17" because its CI deploys are never recorded as
`Deployment`s at all.

**Fix.**
- An app's health derives from its **latest** deploy, not its worst.
- Show "3 apps failing now"; superseded failures move to history.
- Record CI-driven deploys (the GitHub Actions path) as deployments, or the self-deploy
  row is permanently wrong.
- A failed deploy carries a **cause class** (`app_code` / `infrastructure` / `preflight`)
  so "not your fault" is visible — two of this week's failures were Conductor's own bugs.

## 2. Schema + seed state  (M · the one that caused outages)

**Problem.** Conductor runs a gated `db:migrate` during deploy and records nothing.
Between deploys nobody can answer "is this app's schema behind its repo?" — the blind
spot behind two production 500s. Seeds are better off: `SeedApplication` is a real ledger
with status + digest, but it has **0 rows** because only one path writes to it.

**Fix.** At deploy time we already run the command — keep the answer:
- Record `schema_migrations.max` (the applied version) and a digest of the repo's
  `db/schema.rb` per deploy.
- Derive three states: **up to date · N pending · unknown** (never deployed here).
- Surface per app and as a fleet column; make `pending > 0` a preflight warning.
- Expose over MCP so an agent can answer it without a shell.

Deliberately NOT: running migrations outside a deploy. Read-only truth first.

## 3. Backups that are on by default  (M · why 0 of 12)

**Problem.** `Backup` requires provider + bucket + credential + schedule, chosen per app.
Twelve apps × four decisions = nobody does it. The data agrees: **zero**.

**Fix.**
- **Opt-out, not opt-in**: creating an app proposes `nightly 02:00 → R2 · keep 14 days`,
  inheriting an already-connected storage credential. One toggle, not a form.
- Fleet-level **"Protect all N apps"** that applies the same default across the org.
- **Restore test** as a first-class action: restore into a scratch database, diff row
  counts, record the result. A backup nobody restored is unverified, and the UI should
  say `unverified`, never `healthy`.

## 4. Per-app scheduled jobs  (M · the Heroku Scheduler gap)

**Problem.** `CronJob` is **server-scoped**: a shell command on the host, no app env, no
app image, no per-app run history. Heroku's scheduler runs `rake slack:sync` *in a dyno
with the app's environment*. Same word, different feature.

**Fix.**
- Schedules belong to an **app**, execute via `kamal app exec` (or the runtime's
  equivalent) inside the running container, with the app's env.
- Persist each run: exit code, duration, output, next-due.
- Show the **last run's output in the editor** — a scheduler you can't debug from gets
  disabled and forgotten.
- Timeout per job; a failing schedule raises to the app's needs-attention list rather
  than failing silently.

## 5. Job control, not just job counts  (S)

**Problem.** `SolidQueueStats` shows pending/failed/workers. There is no way to act, so
"3 failed" ends in an SSH session anyway.

**Fix.** Retry and discard a failed job from the UI and over MCP; pause/resume a queue.
Show **oldest-waiting** per queue, not just depth — depth without wait time means nothing.
**Never render job arguments**: payloads routinely carry emails and tokens.

## 6. The checklist that makes the rest happen  (S · ties 1–5 together)

Each app gets a small readiness checklist — deploy method, domain + TLS, runbook,
backups, restore tested, schema tracking — where **every unchecked row has a one-click
action with a sensible default**.

Exposed as an MCP action (`conductor_app action=checklist`) returning the same list, so an
agent can do the boring items and raise only real decisions. A checklist that scolds
without fixing is worse than none; the nag is only acceptable because satisfying it is one
click.

## Order

1. **Failure resolution** (#1) — smallest, and it fixes a signal everything else relies on.
2. **Checklist** (#6) scaffold — gives 3–5 somewhere to land.
3. **Backups default-on + restore test** (#3) — the biggest real risk today: zero coverage.
4. **Schema/seed state** (#2) — has already cost two outages.
5. **Job control** (#5), then **per-app schedules** (#4) — the largest, needs runtime work
   per deploy method.

## Open questions

- **Q-07-1.** Do CI-driven deploys become `Deployment` rows (a webhook from the workflow),
  or does the app page label them "via CI" and link out? The first is honest, the second
  is free.
- **Q-07-2.** Restore-test target: a scratch database on the same cluster, or a throwaway
  container? Same-cluster is cheap and proves the dump; a container proves more.
- **Q-07-3.** Schedules on non-Kamal runtimes (`docker`, native) — is `app exec` available
  everywhere, or does this ship Kamal-first?
