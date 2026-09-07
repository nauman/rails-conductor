# 0015. No build CPU quota — fix the placement instead

Date: 2026-09-07

## Status

**Accepted (2026-09-07).** Closes the open question left by ADR 0014.

## Context

ADR 0014 moved builds onto Conductor's own control machine and left a CPU ceiling
"not built, and it needs a decision". A host-wide `flock` shipped with it, so only
one build runs at a time.

The remaining proposal was a `--driver-opt cpu-period/cpu-quota` on the buildx
worker, re-verified before every build because Kamal creates and manages that
worker and will recreate it unconstrained.

## Decision

**Do not build the quota.**

The question is not "how do we cap a build". It is "why is a build competing with
served traffic at all". A CPU ceiling is a mitigation that makes the wrong placement
survivable, and paying for it means Conductor permanently owning the lifecycle of a
resource Kamal manages — checking before each build, refusing when Kamal has
replaced the worker, and losing that argument quietly whenever the check is missed.
That is the same two-things-managing-one-resource shape as overruling a repo's
`builder.remote`, which this fleet already rejected.

What actually bounds the cost:

1. **The lock**, which is built. Concurrency was the case that hurt: one build on a
   12-core box at low baseline load is survivable, several are not.
2. **`build_venue: builder`**, which is built. A box that serves nothing is the real
   answer for a fleet that outgrows the control machine.

## Consequences

**Accepted:** a single large build can still take a noticeable share of the control
machine. On the current fleet that is a machine with twelve cores and roughly four
percent baseline load, so the exposure is small and measurable rather than unknown.

**Revisit when** any of these becomes true — and they are the trigger, not a vague
"if it hurts":

- more than one app builds on a schedule that overlaps regularly,
- the control machine's load during a build affects a served response time,
- or a build box exists, at which point the venue moves and the question is moot.

**Rejected:** `nice` and CPU shares. `nice` constrains the Kamal client while the
work happens inside daemon-managed BuildKit containers, and shares are a relative
weight rather than a ceiling. Both look like controls and are not.

Related: ADR 0014 (the venue is chosen, not inherited),
`docs/architecture/01-builder/`.
