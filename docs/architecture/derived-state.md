# Derived state

> **The decision is [ADR 0010](../dev/adr/0010-derived-state-declares-its-refresh.md).**
> This page is the inventory behind it: what Conductor derives, what refreshes each
> value, whether a consumer can tell how old it is, and where the gaps are.

## Why this page exists

A control plane owns almost no facts. It **asks** — over SSH, of a Docker daemon,
of a provider API — and stores the answer. Every stored answer is a photograph, and
the sources never call back to say the subject moved.

That makes one bug endemic rather than occasional: **a snapshot presented as the
present**. It has now appeared four times in different subsystems, and it does not
look like a bug from the outside, because a stale answer and a correct answer are
the same shape. The failure is always silence, never an error.

| Incident | The stale thing | Read as | Cost |
|---|---|---|---|
| Deploy hold | a free-text reason | current blocker | app held 9 days past the fix it cited |
| Live orphan | residue over `exited` containers only | box is clean | stale release ran production jobs 15 days |
| Silent backup | a hardcoded container name | backup works | 3 nights of no-op dumps, after a real restore test passed |
| Missing zone | a Cloudflare cache | live zone list | a domain reported absent for 34 days |

None was caused by a difficult problem. Each was caused by storing a derivation
and not saying when it was taken.

## The three properties

Every derived value needs all three. Two out of three still misleads:

**Refresh** — a named job on a schedule. A UI button is not a refresh; it is a
thing someone has to remember. The Cloudflare cache had a button.

**Age** — `*_checked_at`, persisted *and surfaced beside the value everywhere it is
reported*. Storing the timestamp but omitting it from the MCP payload leaves the
consumer exactly as blind. This is the one most often half-done.

**Staleness threshold** — `STALE_AFTER`, defined next to the refresh so they are
read together, with `stale: true` travelling with the value. The threshold encodes
how fast the underlying thing actually changes, which is a real piece of domain
knowledge and is otherwise lost.

## Inventory

### Complete — all three properties

| Value | Refresh | Threshold | Notes |
|---|---|---|---|
| `servers.last_audit_status` | `ServerAuditCheckJob.sweep`, daily 05:40 | 7d (`audit_fresh?`) | Weighed BEFORE the grade, so a stale finding warns rather than blocking forever |
| `apps.residue_findings` | `ResidueCheckJob.sweep`, hourly :25 | 12h | Findings carry `checked_at` + `stale` into `situation` |
| `apps.release_state` | `ReleaseDriftCheckJob.sweep`, hourly :40 | 12h | Offset from residue so they do not SSH the same boxes together |
| `credentials.zones` | `RefreshCloudflareZonesJob.sweep`, 6h :20 | 1d | Added after the 34-day incident |

### Refreshed, age not exposed to consumers

| Value | Refresh | Gap |
|---|---|---|
| `servers` metrics (`cpu`, `memory`, `disk`, `load`, `uptime`) | `refresh_server_metrics`, 5 min | `last_seen_at` is stored and shown; individual metrics are not separately dated |
| `apps.container_status` | `sync_container_status`, 2 min | `last_status_check_at` exists; `status_fresh?` uses 5 min, but consumers see the status without the age |
| site checks | `monitor_sites`, 5 min | Freshest of the set; drift here is bounded by the interval |

These are low-risk because their intervals are minutes. The pattern still applies:
a 2-minute-old container status is fine, a 2-hour-old one presented identically is
not, and today nothing distinguishes them at the point of reading.

### Stored, never refreshed — the open gaps

These are written once by an operator-triggered action and then never revisited.
They are the same shape as the Cloudflare cache before it was swept.

| Value | Written by | Risk |
|---|---|---|
| `servers.last_update_status` / `_scope` / `_at` | `apply_updates` | "Security updates: none pending" ages badly and reads as reassurance |
| `servers.last_harden_*` | `harden` | A hardening result from provisioning day, presented as current |
| `servers.last_swap_reclaim_*` | `reclaim_swap` | On-demand by design; still undated at the point of reading |
| `servers.edge_checked_at` | edge detection | Column exists; nothing sweeps it |
| `apps.build_host` | recorded by a deploy | Only changes on deploy, so it is *accurate*, but it is silently absent until the first deploy reports it — "not recorded yet" is honest and rare in this table |

`last_update_status` is now the one worth doing next: "security updates: none
pending" is read as reassurance and ages badly, and unlike the audit grade nothing
downgrades it with time.

The audit grade was the previous entry here and is now swept — but automating a
writer to a **gate** exposed two things a manual run had hidden, and both are worth
carrying forward:

**A probe that cannot look must not grade.** Every privileged line in `ServerAudit::PROBE`
uses `sudo -n` and degrades to blank, and blank was graded as the insecure answer.
A box without passwordless sudo therefore graded `at_risk` identically to a box
with its firewall off. Run by hand that is a confusing result; run on a schedule it
silently blocks deploys. The probe now emits `SUDO` and a `PROBE_END` sentinel, and
an incomplete probe returns **no status at all** — which routes through the same
path as an SSH failure, so the old grade stands and staleness accrues visibly.

**Freshness must be weighed before the grade, not inside one branch of it.** The
preflight checked `audit_fresh?` only for `secure`, so a stale `secure` correctly
warned while a stale `at_risk` blocked deploys *forever* — a box fixed months ago
stayed blocked with no way to clear it. An old grade is evidence about the past
whichever way it points.

And the original lesson still holds: `audit_fresh?` existed and was correct, but
nothing could make an audit fresh *again*. **A staleness check without a refresh is
half a mechanism, and the half that does nothing.**

## Failure modes of the refresh itself

Automating a refresh creates two hazards that manual refreshing hides, because a
human notices a weird result and a cron job does not.

**Failing toward empty.** A narrowed Cloudflare token returns **zero zones with a
200**. Written verbatim, that erases the list into a state indistinguishable from
"this account owns nothing", every six hours, unattended.

The first fix refused an empty overwrite outright, and that was wrong in the other
direction: an account whose zones really *were* all deleted or transferred could
never re-verify, while its stale list kept driving `proxyable_apps`. **A permanent
veto is not a safety property, it is a wedge.** The rule is now two-strikes — the
first empty is refused and reported, the second consecutive one is believed, and
any non-empty result resets the count so two empties months apart never add up to a
wipe. Generalised: *a successful-but-empty response is suspicious once and true
twice.*

**Failing toward truncated.** A paginated fetch that stops at a page cap and returns
`success` caches a partial list as though it were complete — the original
truncation bug at a larger number. Reaching the cap now returns failure, so the
previous good cache survives and goes visibly stale instead of being quietly
replaced by a shorter one. Results are de-duplicated by id, since pages can repeat
while the underlying list changes.

**Failing toward blank on error.** A refresh that raises must leave the previous
value untouched and let staleness accrue. A network blip should degrade the answer
to "old", never to "nothing".

Both reduce to the same rule: **a refresh may only ever move a value forward or
leave it alone.**

## Adding a new derived value

1. Name what it is derived *from*, and accept that the source will never notify you.
2. Write the refresh job before the reader. `ResidueCheckJob` is the model: `perform(id)` plus a `self.sweep`.
3. Register it in `config/recurring.yml` on an **offset** minute — the existing sweeps sit at :12, :20, :25, :40 for this reason.
4. Persist `*_checked_at`, and put it in **every** payload that carries the value.
5. Define `STALE_AFTER` beside the job and carry `stale:` with the value.
6. Make the refresh fail toward stale: keep the old value on error, refuse a successful-but-empty overwrite.
7. If the value drives a *finding*, give the finding a ritual (ADR 0007).

## Related

- [ADR 0010](../dev/adr/0010-derived-state-declares-its-refresh.md) — the decision
- [ADR 0007](../dev/adr/0007-findings-cite-rituals.md) — a finding must carry the ritual that resolves it
- [ADR 0006](../dev/adr/0006-a-running-container-must-be-nameable.md) — lifecycle follows purpose; the same "nothing reports it" root
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) — the control-plane overview this elaborates
