# Session: Stale Records and Assigned Identity

**Date:** 2026-08-26 → 2026-09-05
**Scope:** A deploy hold on one app that turned into a fleet-wide audit of how Conductor stores what it learns
**Goal:** Ship the held release, then stop the class of bug that held it

## The Starting Position

One question — *why is Conductor denying this app's deployments?* — and the answer
was that the hold's stated reason was wrong on two of three counts, citing a fix
that had shipped nine days earlier and a build host the app's repo does not
configure.

Every finding after that was the same shape: **a stored value nothing refreshed,
or an identity derived from a name that could change.**

## What Shipped

| Commit | Change |
| --- | --- |
| `e068675`… | the held app released — zero downtime, sha-named container, release drift closed |
| `087817a` | `reclaim_swap` as a vetted action with a 2× headroom guard |
| `a4d2892` | Host `flock`, fail-closed sudoers grant, honest limits on what a job fixes |
| `9178226` | Root is a registration-only credential — enforced by a test that fails the build |
| `7b6e12b` | Residue detector sees the orphan that looks healthy |
| `b64c39f` | ADR 0007 — a finding must cite the ritual that resolves it |
| `56e6cc0` | Findings hand over the ritual, resolved from the specific cause |
| `42bd01b` | A candidate at the current release is the LIVE container, not an orphan |
| `a2adfd6` | Never deploy backwards |
| `bcb3651` | Backups find the container by label, not a name the app outgrew |
| `797939f` | Ops asks the driver question, not the artifact one |
| `4f5381f` | Secrets scrubbed from deployment logs, old and new |
| `14be8a5` / `88ca523` | Cloudflare zone cache dated, paginated, and swept |
| `60c8ae6` | **ADR 0010** — derived state declares its refresh |
| `baaf7f4` | Audit probe: could-not-look ≠ found-a-problem; stale `at_risk` still blocks |
| `498f9f6` | **ADR 0011** — one DB naming convention, assigned identity for shared clusters |

Architecture pages added: `derived-state.md`, `rituals.md`, `database-conventions.md`.

## Incidents Caused While Fixing

Recorded because the session's lesson is mostly in these.

- **471 MiB of swap lost.** A synchronous `reclaim_swap` was severed by a 504
  between its `swapoff` and its restore. Led to ADR 0005 — an interruptible,
  destructive operation must not live in a request cycle.
- **A live production container recommended for `docker stop`.** The new orphan
  detector's second finding named the only container serving a site. Root cause:
  it compared nothing, having replaced a comparison that compared the wrong thing.
- **Production rolled backwards by a green deploy.** Two runs for different commits;
  the older finished last. Fixed by refusing to deploy anything that is not
  `origin/main` HEAD.
- **A security gate weakened.** "Freshness before the grade" turned *a stale
  `at_risk` blocks forever* into *blocks nothing*. Ageing is not a fix.

## The Through-Line

Two failures, over and over:

**A stored value nothing refreshes reads as a fact.** A hold's prose, a zone cache,
an audit grade, a residue rollup. Fixed structurally by ADR 0010: a refresh, an age
surfaced with the value, a staleness threshold — and fail toward stale, never toward
empty.

**An identity derived from a name breaks when the name changes.** A backup's
container name, decommission's filters, `deploy_method` answering a driver question,
a cluster's DNS host. ADR 0004 assigned identity to end this; four subsystems had
never adopted it.

And one about method: **a flag is not a fix.** Visibility was shipped three times as
though it were the cure. Making a problem legible is the diagnostic half.

## Open

See the handoff for the full list. ADR 0011's naming work took **two** adversarial
rounds: the first returned six findings (slug collisions, reserved words, the
63-byte limit, an MCP omit-name path that did not work, an alias recorded without
being attached, and a provisioner sending the base name). The fixes for those drew
a second round of seven — four of the six were *only apparently* fixed. Both rounds
are recorded in ADR 0011's amendments.

The pattern worth keeping: every round-two finding was the same defect one level
in. A fallback namespace that a slug could derive into. An identifier guard the
derivation honoured but a caller-supplied name walked past. A memo that outlived
its input. Fixing the visible instance is not fixing the class, and only an
adversary looking again finds the difference.

What remains open is the operator half: `rake database_naming:audit` reports which
existing apps a naming rule reclassified, and it has to be run against production —
locally it finds one, self-managed, holding no Conductor-provisioned database.

## The one thing that was reverted

An implementation of ADR 0013 (one "sensitive" flag, one guarantee, on every deploy
path) was written, audited, and **reverted unshipped**. It is worth reading the ADR
before attempting it again, because the failure is instructive:

The change moved sensitive values off the `docker run` command line into an env
file — written with a heredoc. **The heredoc is the SSH command string.** So the
value stayed in the remote shell's argv, which is exactly the exposure the change
existed to remove. The same mistake was made twice; a test caught it on the native
path and missed it on the docker path, because that test asserted the value was
absent from `docker run` rather than from the whole command sent over SSH. A test
written by the same hand as the fix inherits the fix's blind spot — this is the
second time that pattern appears in this session.

It would also have destroyed operator-maintained config: provisioning creates the
native `.env` as a placeholder for a human to fill in, and the deploy script
`source`s it as shell, so Conductor writing values into it is both data loss and a
path from a stored string to remote execution.

And the premise was wrong. "Kamal is already compliant" came from reading
`KamalConfig` (pointers) and not `KamalEnvWriter` (raw values).

## Notes for Next Time

Two constraints in that work were found by RUNNING rather than reading:
`docker run --env-file` silently truncates a multiline value to its first line, and
it hides nothing from `docker inspect`. Neither is discoverable by inspection, and
both would have shipped as a silently corrupted credential.

`codex exec` earned its place: it returned *not safe* three times on work whose
tests were green, twice catching regressions introduced by the previous fix. Tests
pass because they assert what was intended. **Audit before deploying, not after** —
the reverse order caused at least one of the incidents above.
