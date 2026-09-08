# Session: The Gate That Never Ran

**Date:** 2026-09-07 → 2026-09-08
**Scope:** A migration gate that had never executed, the ordering that made it
unsafe, and a verification loop that reported success four times without running
**Method:** implement → adversarial audit → fix → re-audit, five rounds

## What shipped

`f13f119` — the migration gate runs for docker apps, before anything stops.
`2032e09` — the learning behind the near-miss below.

Both shipped through CI and are live; the control plane answered 200 after the roll.

## The defect

`AppDeployer#run_gated_migrations` opened with:

```ruby
return true unless app.kamal?
```

`AppDeployer` only ever serves **docker** apps — kamal apps go to `KamalDeployer`,
native to `NativeDeployer`, dispatched in `DeployAppJob`. The guard was
unreachable. The gate had never run once for any app it was written for, and
every docker release had been publishing without checking its schema.

It is a one-line bug that reads as obviously correct in isolation. What made it
survive is that the line is *true* — a docker app is not a kamal app — so nothing
about reading it suggests the method it guards can never be reached.

## Three things the audit changed

**Declared, not probed.** The first two fixes inferred whether an app migrates by
probing the image. Both failed OPEN: `test -f bin/rails` returns 1 for a denied
path traversal as well as a missing file, and running the probe needs
`--entrypoint sh`, which bypasses any `cd` the real entrypoint performs — so a
working Rails image reads as "does not migrate" and loses its gate silently. A
guess that fails open on a safety check is worse than no check, because it looks
like one. The answer is now a column someone sets.

**Ordering was half the bug.** The gate ran against the new release container, so
on the stop-first path the incumbent had *already been removed* by the time
migrations ran. A failed migration therefore left the app down, under a log line
claiming the previous release kept serving. It now runs in a throwaway container
built from the new image, before anything is stopped: no host port, so no
collision, and a failure means nothing has been touched.

**No grandfather clause, after writing two.** The first backfill switched every
non-kamal app off, so no existing Rails app would gain the gate. The second
narrowed it to apps with no database Conductor knows of — and it switched off
Conductor itself and one other Rails app, because their `DATABASE_URL` is not an
`env_variables` row. A heuristic that misses the apps it exists to protect is not
a heuristic, it is a silent opt-out. Both were deleted. The column defaults on for
everyone, which the ordering fix is what makes safe: the worst case for an app
that cannot migrate is an aborted rollout that never moves the running container,
and an error naming the checkbox to clear.

## The near-miss: four verifications that never ran

While iterating on the migration body, the loop was
`bin/rails db:rollback STEP=1 && bin/rails db:migrate`, then confirm the column.

Conductor is a multi-database app, so the un-namespaced `db:rollback` **aborts** —
it needs `db:rollback:primary`. The version stayed in `schema_migrations`,
`db:migrate` then had nothing to do and exited 0, and the column existed from the
migration's *first* version. Every check passed. The backfill being verified had
never executed once. `| tail -1` hid the abort message.

What exposed it was checking the **effect** rather than the schema: the backfill
was supposed to set rows to `false`, and no row was `false`.

Written up as `docs/learnings/db-rollback-aborts-silently-on-multi-database.md`.
The general rule: a migration edited after it has been applied is not the
migration that ran, and nothing in `db:migrate:status` can tell them apart.

## What the audit would not let go, and was right about

Tests that call a private method prove it refuses; they prove nothing about
whether the deploy reaches it, or reaches it while the previous release is still
up. The suite now asserts **where** the gate sits in both step orders. Verified by
mutation — moving it after `stop_old_container`, dropping the env flags, and
migrating the wrong image each fail.

Two vacuous assertions were removed rather than kept: both the guarded and the
destructive branch of `discard_candidate` return false, so asserting on the return
value passed either way. The real evidence is what never reached the shell.

## Left open, deliberately

**Serving identity is still guessed.** `resolve_serving_container` picks the first
running container carrying the service label; it does not ask the edge which one
receives traffic. So when `discard_candidate` spares a container it adopted as
already-serving, that container is either the incumbent (deleting it is an outage)
or a leftover from an interrupted attempt (leaving it is an orphan), and we cannot
tell which. The asymmetry decides — an outage is worse than an orphan — but the
log now says exactly that and points at a residue check, instead of implying it
knows. Resolving it properly means reading serving identity from the edge.

**Multi-database apps have no ritual.** Conductor's own `database.yml` declares
four configs in production (`primary`, `cache`, `queue`, `cable`), each with its
own `migrations_paths`. Nothing in Conductor records that an app is multi-DB, so
the trap above cannot be checklisted yet. The design is settled: jazari resolves
one recipe per *subject*, but one recipe serves many subjects — so a single
`multi-database-app` recipe attaches to a second subject per app via
`Jazari::AnchorTarget` (scope `app`, key `databases`), leaving the deploy ritual
untouched. Open question is only how Conductor learns the fact; deriving it from
the live container must fail closed.

**One new app's setup is blocked on its repository.** The target box, the DNS
state, and the build-venue decision it needs are all settled and recorded; the
only missing fact is where the code lives, which no search of the accessible
repositories or checkouts turned up. Tracked in the machine-local thread
`~/.agents/threads/hushnote/setup-on-small-server.thread.md` — app-specific
threads stay out of this repo, which is public.
