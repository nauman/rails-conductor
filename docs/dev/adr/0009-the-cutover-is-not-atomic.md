# 0009. The cutover is not atomic, and says otherwise

Date: 2026-08-27

## Status

**Proposed (2026-08-27).** Not implemented. Split out of ADR 0006's implementation,
where an adversarial audit surfaced these while reviewing an unrelated change.

## Context

ADR 0003 describes the zero-downtime cutover as *candidate → health → swap →
drain*. Reviewing a change to that sequence turned up two defects that pre-date it
and are independent of it. Both share a shape: **the deploy reports success in
states where it has not succeeded.**

### 1. A failed drain cannot fail the deploy

`drain_previous_container` reads as if it guards against leaving two containers up:

```ruby
stopped = run("docker stop #{...} 2>/dev/null || true")
removed = run("docker rm   #{...} 2>/dev/null || true")
...
return true if stopped && removed
fail_step("traffic moved to the new release, but draining … failed …")
```

Both commands end in `|| true`, so both always exit zero, so `stopped` and
`removed` are always truthy and **`fail_step` is unreachable**. The comment above it
states the exact risk — "it leaves two containers running, which must not pass as
success" — and the code passes it as success.

What that produces is not hypothetical. Two containers of the same app running
against one database is precisely the fifteen-day orphan of ADR 0006: the drained
one serves no traffic, so every external check stays green while it keeps consuming
the shared job queue on the release that just got superseded.

### 2. Edge publication is not all-or-nothing

`publish_edge` mutates Caddy hostnames one at a time. If a later hostname fails,
`compensate_failed_cutover` removes the candidate — while the hostnames that
already moved still point at it. Those routes now target a deleted container.

The compensation's assumption, that the incumbent is still serving everything, holds
only when *nothing* was published. It is written as though publication were atomic,
and it is a loop.

The same ambiguity exists for a lost response: the edge command may have taken
effect while the reply never arrived, so Conductor believes it did not.

## Decision

**A deploy step that cannot fail must not pretend it can, and a partial mutation
must be recoverable.**

1. **Stop swallowing drain failures.** Drop `|| true`, distinguish "already gone"
   from "could not remove", and let a genuine failure fail the step — traffic is
   already on the new release, so failing here is loud, not dangerous. The honest
   alternative, if a failed drain should not fail a deploy, is to say so and delete
   the unreachable branch. Either is better than a guard that reads as protection
   and is not.
2. **Snapshot the edge before mutating it.** Record which hostnames pointed where,
   so compensation restores what it changed instead of assuming nothing changed.
3. **Treat an ambiguous edge response as published, not as failed.** Re-reading the
   route is cheap; deleting a container that might be serving is not.

## Consequences

**Accepted:**
- Deploys that currently pass will start failing. That is the point — they were
  failing already, silently, and the failures are recoverable by hand precisely
  because traffic has already moved.
- Multi-hostname Caddy apps get slower cutovers for a snapshot they will rarely use.

**Costs:**
- Restoring routes needs a place to keep the snapshot that survives the process, or
  it inherits the durability problem of ADR 0005. In-memory is enough for the loop
  failure and not for a killed worker; that limit should be written down rather than
  assumed away.

**Rejected:**
- *Leave it, since the drain rarely fails.* The residue this hides is the residue
  that cost fifteen days of a stale release running production jobs.
- *Fix it inside the ADR 0006 change.* Unrelated blast radius. The audit found them
  together; that is not a reason to ship them together.

## Status detail

| Step | State |
|---|---|
| Decision recorded | Done — this ADR |
| Drain reports its own failures | Not built |
| Edge snapshot + restore on partial publication | Not built |
| Ambiguous edge response treated as published | Not built |

Related: ADR 0003 (the cutover), ADR 0005 (surviving the caller's death),
ADR 0006 (the orphan this silently produces).
