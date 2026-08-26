# 0006. A running container must be nameable, and temporary things get temporary lifecycles

Date: 2026-08-26

## Status

**Accepted (2026-08-26), amended 2026-08-27.** Rule 1 is implemented. Rule 2 was
amended after implementation proved one of its assumptions false — see
*Amendment* below.

## Context

A candidate container created by a cutover experiment on 2026-08-11 was still
running production jobs on 2026-08-26. Fifteen days, unnoticed.

```
Created:       2026-08-11T07:52:09Z
StartedAt:     2026-08-26T12:33:58Z   (came back with the reboot)
RestartPolicy: unless-stopped
Ports:         127.0.0.1:20070 -> 3000
Labels:        conductor.candidate=true, service=app-7, conductor.release=<old>
```

It never served a request — the edge pointed elsewhere, so every external check
was green the entire time. What it *did* share was the job queue. It claimed and
executed payment- and invitation-recovery jobs with code that was already stale
when it started and twelve days staler by the end, against a schema that had
migrated forward underneath it.

Four independent failures had to line up, and each is worth naming separately
because each has its own fix:

**1. A temporary artifact was given a permanent lifecycle.** `--restart
unless-stopped` is correct for a release container and wrong for a candidate. It
means "come back on daemon start unless a human explicitly stopped you", and
nobody ever stops an experiment they walked away from. The reboot did not create
this problem; it faithfully restored it.

**2. Nothing recorded that the container was transient.** No owner, no expiry, no
end. An experiment that ends by being abandoned leaves no signal distinguishable
from an experiment still in progress.

**3. Residue detection only looks at `exited` containers.** This one reported `Up
(healthy)`, so it was invisible to every `situation` read for fifteen days. That
is exactly backwards: a dead container holds no traffic and does no work, while a
live orphan does both. **The dangerous residue is the kind that looks healthy.**

**4. Nothing ever asked the box what else was running.** Conductor knew which
release it believed was current. It never compared that against the set of
containers actually up for the app. Health was checked per-app, one container
deep — the sixth container was outside the question's shape.

The through-line: Conductor verified the things it had put there, and had no
concept of a thing it had *not* put there.

## Decision

**Two rules.**

### Rule 1 — Lifecycle follows purpose, not convention

Every container Conductor creates declares what kind of thing it is, and the
restart policy is derived from that, never chosen ad hoc:

| Kind | Restart policy | Survives reboot |
|---|---|---|
| `release` — serving the current release | `unless-stopped` | yes |
| `accessory` — declared DB, cache, proxy | `unless-stopped` | yes |
| `candidate` — cutover, canary, experiment | **`no`** | **no** |
| `task` — one-shot migration, console, runner | **`no`** | **no** |

A candidate that does not survive a reboot cannot rot for fifteen days. The reboot
becomes a free sweep rather than a resurrection event. Candidates additionally
carry `conductor.expires_at`, so they can be reaped without waiting for a reboot.

### Rule 2 — A running container must be nameable

For every app, Conductor must be able to answer, for each container on the box:
**why is this running?** The legitimate answers are exactly: it is the current
release, it is a declared accessory, or it is an unexpired candidate of an
in-flight operation. Anything else is an **orphan** and is reported, whatever its
health says.

This inverts the current check. Today Conductor asks "is what I expect healthy?"
It must also ask "is anything here that I do not expect?" — those are different
questions, and only the second one finds this.

**The queue is the cheapest orphan detector we have.** For any app running
SolidQueue, more than one distinct hostname in `solid_queue_processes` means more
than one live copy of the app, full stop. It needs no labels, so it catches
orphans that label-based reconciliation misses — hand-run containers, a stray
`docker run`, a copy on another host entirely. One query, unambiguous signal:

```
SELECT COUNT(DISTINCT hostname) FROM solid_queue_processes;  -- > 1 ⇒ orphan
```

## Consequences

**Accepted:**
- Creating a container requires stating its kind. There is no default; an
  unlabelled container is an orphan by construction, which is the intended
  pressure.
- Reboot recovery gains a reaping step and an orphan report. `RebootRecoveryJob`
  already walks the box after a reboot — it verified five apps and missed the
  sixth container, so the walk exists and the question was simply too narrow.
- Orphan findings will surface as `attention` even when everything is green.
  That is the point; a green fleet with a live orphan is not green.

**Costs:**
- A candidate that legitimately needs to outlive a reboot must now say so
  explicitly with an expiry. This is friction, and it is where the fifteen days
  came from, so it is friction worth having.
- The queue check is app-shaped, not container-shaped: it proves a second copy
  exists without saying where. It is a detector, not a diagnosis — pair it with
  label reconciliation to locate the thing.

**Rejected:**
- *Just delete the stale container.* Fixes the instance, not the class. The
  experiment that made it will happen again.
- *Stop labelling candidates as candidates and treat them as releases.* Removes
  the distinction that makes reaping safe.
- *Rely on the operator to clean up experiments.* Fifteen days of evidence says
  otherwise, and an operator cannot clean up what nothing reports.

## Amendment (2026-08-27): a label cannot be the source of truth

Implementing Rule 2 surfaced a fact that invalidates the obvious version of it:
**Docker labels are immutable after container creation.** A candidate that wins a
cutover cannot be re-badged, so `conductor.candidate=true` stays on the container
serving production for the rest of its life. There is no "promote by relabelling".

This is not a detail — a detector that trusted the label reported a live release as
an orphan and recommended stopping it. See
`docs/learnings/a-findings-remedy-is-a-production-action.md`.

So identity is decided by **comparison, not by the label**:

> A container is the release when its `conductor.release` equals the app's last
> successful deployment commit. Different release ⇒ superseded. The
> `conductor.candidate` label narrows the search; it never settles the question.

What *is* mutable is the **restart policy** — `docker update --restart` works on a
running container. That turns out to be the better lever anyway, because it is the
one thing that actually differs between an experiment and a release:

- a candidate is created `--restart no`, so an abandoned one is reaped by the next
  reboot instead of resurrected by it
- `#promote_candidate` raises it to `unless-stopped` after the edge has swapped and
  the previous container has drained

The fifteen-day orphan becomes impossible at creation rather than merely findable
afterwards, which was the point of Rule 1.

## Status detail

| Step | State |
|---|---|
| Decision recorded | Done — this ADR |
| Candidates created `--restart no`; promoted after the drain | **Done** — `AppDeployer` |
| Identity by release comparison, not by label | **Done** — `ResidueDetector` |
| ~~Relabel the winner~~ | **Impossible** — Docker labels are immutable; superseded by the amendment |
| `conductor.expires_at` on candidates | Not built — reboot reaping now covers the main case |
| Orphan reconciliation (containers-on-box vs expected set) | Not built |
| SolidQueue distinct-hostname check as a fleet finding | Not built |
| Reap candidates + report orphans in `RebootRecoveryJob` | Not built |

Related: ADR 0004 (stable resource ids — the naming this candidate used),
ADR 0005 (host-side transactions), `docs/learnings/form-changes-leave-residue.md`.
