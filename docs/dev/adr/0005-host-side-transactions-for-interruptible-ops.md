# 0005. Host-side transactions for interruptible privileged operations

Date: 2026-08-26

## Status

**Accepted (2026-08-26).** Partially implemented — the classification and the
host-side lock are in place; the durable executor is not. See status below.

## Context

Conductor ran a swap-reclaim (`swapoff -a` then restore) inside an MCP request.
The proxy returned 504 before the SSH chain finished, the request was severed
mid-`swapoff`, and the restore step never ran. A production box came out of it
with **471 MiB less swap than it started with**, reported as a timeout rather than
as damage.

The instinct is to blame the timeout and raise it. That is the wrong lesson twice
over.

**First, the script could not have saved itself.** The wrapper had correct restore
logic — capture `/proc/swaps`, restore each device, verify. None of it ran, because
the process holding it was killed. No amount of care *inside* a script survives
that script's process dying. Defensive logic protects against bad input, not
against not existing.

**Second, moving it to a background job does not close the hole either.** The SSH
channel is still owned by the worker. Solid Queue's graceful shutdown waits briefly
and then terminates; an abrupt worker loss severs the remote shell exactly as the
504 did. A job reduces the exposure window from "any proxy timeout" to "a worker
restart", which is real but is not the same as safety. Claiming otherwise is how a
half-fix gets recorded as a fix and stops being worked on.

The distinction that actually matters is not sync versus async. It is:

> **What state is the remote host left in if the caller disappears halfway?**

Most Conductor operations answer that harmlessly. `apply_updates` is driven by apt,
which has its own recovery. A severed deploy leaves the incumbent running (ADR
0003) and is retryable. But an operation that **takes a resource away before giving
it back** has a window where the box is strictly worse off, and that window belongs
to the host, not to Conductor.

## Decision

**Classify every privileged operation by its interruption semantics, and give
"destructive-then-restorative" operations a transaction that lives on the host.**

Three classes:

| Class | Interruption leaves | Requirement |
|---|---|---|
| **Idempotent** — audit, metrics, inventory | nothing changed | may run in a request |
| **Retryable** — deploy, apply_updates, install_packages | a recoverable or self-healing state | background job |
| **Destructive-then-restorative** — swap reclaim, anything that stops X to start X' | the host materially worse off | **host-side transaction** |

For the third class, three properties are required, in order of how much they buy:

1. **A host-side lock**, so a second attempt cannot land on a half-finished first.
   This is the one that prevents compounding the damage, and it must live on the
   host: a Ruby-side check cannot stop another worker, another Conductor instance,
   or a human on the box.
2. **Verified completion** — the operation asserts the end state it promised and
   reports a distinct, loud failure when it cannot reach it. "Swap is off and did
   not come back" must never be indistinguishable from a generic error.
3. **An executor that outlives the caller** — a root-owned systemd unit that
   Conductor *starts* and then *polls*, so severing the SSH connection stops the
   watching, not the work.

## Consequences

**Accepted:**
- A new privileged operation must state its class before it is wired up. "Which
  class is this?" is a review question, not an afterthought.
- Comments and commit messages must not describe a reduced exposure as a closed
  hole. The `ReclaimSwapJob` header carries its own honest limit for this reason.
- Operations in class 3 will be more work than they look. That is the point: they
  are the ones that can leave a box degraded.

**Costs:**
- The durable executor (property 3) is real complexity — a unit file, state on
  disk, a polling protocol — and is not yet built. Until it is, class-3 operations
  carry a documented residual risk rather than a false guarantee.
- `flock` requires the wrapper to hold a lock file, which a `swapoff` hang can hold
  indefinitely. Preferred over the alternative: the lock's absence is what allowed
  the damage to compound.

**Rejected:**
- *Raise the proxy timeout.* Treats a symptom, and the operation would still die on
  a worker restart or a deploy of Conductor itself.
- *Make the script more defensive.* Already was. Irrelevant to a killed process.
- *Refuse to build class-3 operations.* Reclaiming swap is legitimate and useful;
  the answer is to run it correctly, not to leave the operator to `ssh` it by hand,
  which is strictly worse — no lock, no verification, no record.

## Status detail

| Property | State |
|---|---|
| Classification recorded | Done — this ADR |
| Host-side lock | Done — `flock` in `conductor-reclaim-swap` (`ServerSudo`) |
| Verified completion + distinct failure codes | Done — exit 3/4/5/6, surfaced by `ServerSwapReclaim` |
| Enqueue-time in-flight guard | Done — `ServerSwapReclaim.in_flight?` |
| Executor that outlives the caller | **Not built.** Residual risk: a worker killed mid-`swapoff` |

Related: ADR 0003 (one deploy path — a severed deploy leaves the incumbent
running), `docs/learnings/root-is-a-registration-only-credential.md` (the adjacent
rule about which identity performs privileged work).
