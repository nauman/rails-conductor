# Session: Identity, Secrets, and the Shell

**Date:** 2026-09-06 → 2026-09-07 (overnight, unattended)
**Scope:** Make Conductor install its own SSH key, stop putting credentials on
command lines, and decide where builds run
**Method:** implement → adversarial audit → fix → repeat, four rounds

## What shipped earlier and is live

`fe2c936` and before: the Kamal contract made compulsory, the Caddy shared-gate
overwrite fixed, CI's `startup_failure` no longer read as a broken commit, the build
venue made an explicit choice, and a host-wide build lock. Deployed and verified.

One app's wildcard subdomain TLS was repaired and verified live — a hostname invented on
the spot issued a valid certificate, which is the only evidence that distinguishes
working issuance from a cached cert.

## What this session built

| | |
|---|---|
| `ServerIdentity` | Conductor installs its OWN key, at registration and via `repair_identity` |
| `DeployEnv` | one place deciding how env reaches a container; secrets by file, not argv |
| `/caddy/ask` | Conductor answers the on-demand TLS gate, so a box can serve many zones |

## The through-line: the shell is where the bugs live

Four audit rounds. Every round found real defects, and the pattern is specific
enough to be worth naming: **a shell command that reads correctly and behaves
differently.**

- `awk "NF && !seen[$0]++"` — Ruby consumed the backslash, the inner shell expanded
  `$0` before awk ran, the dedupe key became a constant. **Three keys in, one key
  out, exit status 0.** Intended to stop `cp` deleting keys; deleted more of them.
- `sort -u` — deduplicates by REORDERING, and sshd uses the **first** matching
  entry. So it can promote `no-pty KEY` above `restrict KEY` and grant what the
  operator prohibited.
- An `awk` presence check comparing field 2 — an options-bearing entry
  (`from="..." ssh-ed25519 BLOB`) puts the key in field 3, so the check read
  "absent" and would have appended an **unrestricted** copy of the same key.

Two of those three made access *less* restricted than the code they replaced. None
was visible by reading. All three were found by rendering the command and running it
against real files, which is now the standing method for anything that reaches a
shell.

## The other repeated shape: redaction mistaken for protection

The repository deploy key was base64'd into the SSH command, with the *logged* copy
redacted. Base64 is reversible, so the private key sat in the remote process's argv;
the redaction hid it from us and not from the host. The same applies to env vars: a
value marked sensitive is now kept out of argv, but it is still in the container's
environment and still visible to `docker inspect`. That is inherent to environment
variables and is stated wherever the flag is described, so it cannot over-promise.

## Verification that actually verifies

`ServerIdentity` proves the key works by opening a connection restricted to that key
— `keys_only`, no agent, no `~/.ssh/config`. Without the restriction Net::SSH offers
agent identities, so the check could pass on the **operator's** credential while
Conductor's own was absent: a verification that succeeds exactly when it should fail.

The same principle appears in `ServerAudit`, ADR 0010, and the residue detector.
It keeps having to be re-learned in each new place.

## Deliberately not done

- **The native secrets path.** Rewriting its `EnvironmentFile` destroys
  operator-maintained config, and the deploy script `source`s that file as shell —
  so writing values into it turns a stored string into remote execution. This is the
  second time this work has been scoped out for those reasons; see ADR 0013.
- **Switching any box onto `/caddy/ask`.** It moves the dependency: the box would
  call Conductor over the network, so Conductor being down stops new certificates
  issuing. A real trade, and a per-box decision.
- **A CPU ceiling for builds.** The lock exists; the quota needs Conductor to own
  the buildx worker lifecycle, which is a decision (ADR 0014).
- **Migrating existing apps** onto the kamal contract or an explicit build venue.
  Both are ready, both are deliberately one-at-a-time.

## Notes for next time

Four rounds is not a success story. Each round's fix introduced something the next
round caught, twice in the direction of weakening security. The useful conclusions:

1. **Render the command and run it.** Every shell defect here was invisible in
   review and obvious in execution.
2. **A fix to a security control deserves the same suspicion as the bug.** Two of
   these were more permissive than what they replaced.
3. **Stop when the rounds stop converging.** That judgement was deliberately asked
   of the auditor at the end rather than assumed.
