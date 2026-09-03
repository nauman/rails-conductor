# 0010. Derived state declares its refresh, or it is not stored

Date: 2026-09-03

## Status

**Accepted (2026-09-03).** Partially implemented — three of Conductor's derived
facts now satisfy it, the server rollups do not. Full inventory and gap analysis in
[`docs/architecture/derived-state.md`](../../architecture/derived-state.md).

## Context

Conductor answered "which Cloudflare account owns this domain" from a cached zone
list that was written on 30 July and refreshed by nothing. It was **34 days old**.
It reported a real domain as absent, and a deleted one as present. Because the
answer carried no age, readers took a snapshot for live state and went looking for
a token-permissions problem that did not exist.

That is not a Cloudflare bug. It is the fourth appearance in one week of a single
failure, each time in a different subsystem:

| Stale thing | Read as | Cost |
|---|---|---|
| A deploy hold's free-text reason | current blocker | app held 9 days past the fix it named |
| Residue detection over `exited` containers only | box is clean | live orphan ran production jobs for 15 days |
| A backup's hardcoded container name | backup works | 3 nights of silent no-op dumps |
| A Cloudflare zone cache | live zone list | a domain reported absent for a month |

The shared mechanism: **a derived value was stored, nothing refreshed it, nothing
recorded its age, and so it was indistinguishable from a fact.**

Conductor is a control plane. Almost everything it reports is derived — from SSH,
from the Docker daemon, from a provider API — and none of those sources notify it.
Every such value is a snapshot the moment it is written. Storing one without
saying when it was taken hands the reader a claim about the present that is
actually a claim about the past.

There is a second, worse failure that only appears once refresh is automated: a
provider returning **success with an empty result**. A narrowed Cloudflare token
returns zero zones with a 200, and writing that erases the list into a state
indistinguishable from "this account owns nothing" — unattended, on a schedule.

## Decision

**Any value Conductor derives from an external source and stores must declare
three things at the point it is defined:**

1. **A refresh** — a named job on a schedule. Not "someone re-runs it", not a UI
   button alone. If nothing refreshes it, it must not be stored; compute it live or
   do without.
2. **An age** — a `*_checked_at` persisted, and **surfaced in every output that
   carries the value**. A consumer cannot judge a snapshot it cannot date.
3. **A staleness threshold** — a `STALE_AFTER` in the same file as the refresh, so
   the two are read together, with `stale: true` travelling beside the value.

And, for the refresh itself:

4. **Fail toward stale, never toward empty.** A failed refresh leaves the previous
   value intact and marks it stale. A *successful* response that would empty a
   populated value is refused and reported, because stale is recoverable and
   silently empty is not.

**A flag is not a fix.** Marking a value stale makes it legible; it does not make
it current. Shipping only the flag was done three times in one week here, each
time feeling like progress and each time leaving the actual problem in place.
Visibility is the diagnostic half; the refresh is the fix.

## Consequences

**Accepted:**
- More scheduled jobs and more network chatter. Cheap next to answering from a
  month-old snapshot.
- Every MCP and UI surface that reports derived state grows two fields. The
  `situation` worklist already does this and is the model.
- "What refreshes this?" becomes a review question for any new stored derivation.

**Costs:**
- Sweeps must be offset or they stampede — the existing ones already are, on
  staggered minutes.
- A staleness threshold is a guess until something measures the real change rate.
  Writing the guess down beats leaving it implicit.

**Rejected:**
- *Compute everything live.* Tried and rejected for residue: it makes four SSH
  round-trips and hung a page render. The stored-rollup pattern exists for good
  reasons; this ADR constrains it rather than replaces it.
- *A global TTL.* Zone lists, container status and audit posture change on
  different timescales; one number would be wrong for all three.
- *Trust the writer to remember.* This is what produced all four incidents.

## Status detail

| Derived value | Refresh | Age surfaced | Stale threshold |
|---|---|---|---|
| `apps.residue_findings` | `sweep_residue`, hourly | yes | 12h |
| `apps.release_state` | `sweep_release_drift`, hourly | yes | 12h |
| `credentials.zones` | `sweep_cloudflare_zones`, 6h | yes | 1d |
| `servers.last_audit_status` | **none** | partial | **none** |
| `servers.last_update_status` | **none** | partial | **none** |
| `servers.last_swap_reclaim_*` | **none** (on demand) | partial | **none** |
| `servers.edge_checked_at` | **none** | partial | **none** |
| `apps.build_host` | written by deploy only | no | **none** |

Related: ADR 0007 (a finding must cite its ritual), ADR 0006 (lifecycle follows
purpose), `docs/architecture/derived-state.md` (the full inventory).
