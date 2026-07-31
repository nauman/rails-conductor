# 0003. One deploy path; Kamal as artifact contract and ops CLI, not deploy driver

Date: 2026-07-31

## Status

**Accepted (2026-07-31).** Supersedes the framing of ADR 0001 (which assumed
Kamal apps are a distinct class) and settles the question ADR 0002 left open
after its rejection: how the fleet gets one deploy story without rebuilding
kamal-proxy's handoff.

## Context

Conductor has three deploy methods (`kamal`, `docker`, `native`) and two edges
(`kamal_proxy`, `caddy`), modelled as if deploy method implied edge. It does not.
Every combination is real, and the mismatch produced two production incidents in
one day:

- A **stranded kamal deploy lock** blocked three consecutive CI deploys.
  Conductor was deploying itself with Kamal from inside the container Kamal was
  replacing; the process died before releasing the lock
  (`docs/learnings/deploy-lock-stranded-by-self-deploy.md`).
- A **502 on Starrrs**, a *docker*-deployed app behind *kamal-proxy*, because the
  docker path never repointed the proxy at the new container — under a green
  "succeeded" (`docs/learnings/form-changes-leave-residue.md`).

Both are the same root problem: **Kamal was treated as a deploy *mode* rather
than as a set of conventions**, so Kamal assumptions leaked into non-Kamal paths
(45 files under `app/`, 51 production Ruby files) while non-Kamal paths lacked
the lifecycle Kamal provides.

The obvious responses were both wrong:

- *Remove Kamal* — loses the release transaction (candidate → health → swap →
  verify → drain), rollback artifacts, and the developer's ability to reach a
  container, its logs, and a console. ADR 0002 was rejected for exactly this.
- *Keep Kamal as the capable path* — leaves two deploy engines, two edges, and a
  permanent "which form is this app in?" question on every feature.

## Decision

**One deploy path. Kamal is retained as an artifact contract and an operations
CLI — not as the thing that performs deploys.**

Kamal is two separable things, and only the first is fragile:

| | What it is | Decision |
|---|---|---|
| Deploy driver | build → push → SSH → cutover → **global lock** | **Not used by Conductor.** Source of both incidents. |
| Artifact convention + ops CLI | SHA-tagged images, container labels, `rollback` / `logs` / `exec` / `console` | **Retained.** This is the value. |

`kamal rollback <version>` boots the image tagged `<version>` on the host.
`kamal app logs` / `exec` / `console` locate containers by their `service`
label. **None of these ask who performed the deploy** — they act on artifacts.
So Conductor can own one deploy path and still hand developers the whole Kamal
ops surface, provided the artifacts follow the conventions.

### The artifact contract

Conductor's deploy path MUST produce:

1. **Immutable, SHA-tagged images** — `<registry>/<image>:<sha>`, not `:latest`.
2. **Kamal-compatible container labels** — `service`, `role`, `destination`.
3. **Retained prior images**, so a rollback target exists. No blanket prune.
4. **A real `config/deploy.yml`** in the repo, for every deploy method — so the
   Kamal CLI can resolve host/service/registry. This is ADR 0001, widened from
   "Kamal apps" to "all apps".

### The edge is an independent axis

Proxy choice is **configuration, not a consequence of deploy method**. A server
is fronted by kamal-proxy or Caddy; the deploy path publishes through the
`Edge.for(server)` abstraction either way. An edge that targets a **container
id** (kamal-proxy) must be republished on every container replacement; one that
targets a stable **host:port** (Caddy) needs nothing.

## Consequences

### Gained

- One deploy path to reason about, test, and harden — instead of three with
  uneven capability.
- Rollback, logs, exec and console become available to **every** app, including
  docker and native ones, without Conductor implementing them.
- The self-deploy inversion disappears: Conductor ships from CI with the same
  path and no global lock to strand.
- ADR 0001 becomes more valuable, not less — the self-describing repo is what
  makes the ops CLI work against a Conductor-performed deploy.

### Costs and risks

- **Conductor owns the release transaction.** This is the real price, and it is
  the objection that rejected ADR 0002. Candidate → health → swap → verify →
  drain must be built and trusted before any app depends on it.
- **Kamal's labels are not a documented public API.** ✅ *Resolved:* the gem is
  pinned (`~> 2.10`) and `test/services/kamal_label_contract_test.rb` asserts
  `service`/`role`/`destination` against the installed gem's
  `Kamal::Configuration::Role#default_labels`, so an upgrade that renames a label
  fails at CI instead of silently blinding the ops CLI.
- **`kamal rollback` acquires the deploy lock.** ✅ *Verified* against kamal
  2.12.0: `Kamal::Cli::Main#rollback` wraps its work in `modify(lock: true)`. So
  rollback DOES re-enter lock territory. Mitigated: `run_kamal_rollback` reclaims
  a stale lock only when `reclaimable_lock?` allows it — never for a self-managed
  app, where CI may legitimately hold it. A self-managed rollback blocked by a
  stale lock needs a manual release; that is the documented cost.
- Until the contract lands, docker apps have **no rollback at all** — the image
  is pruned seconds after it is built.

## Implementation status

| Requirement | Status | Location |
|---|---|---|
| SHA-tagged images | ✅ shipped | `AppDeployer#build_image` |
| Kamal container labels | ✅ shipped — `service` is the stable resource key | `AppDeployer#start_container` |
| Retain prior images | ✅ shipped — keeps `RETAINED_RELEASES` (5) | `AppDeployer#cleanup` |
| **Rollback for docker apps** | ✅ shipped | `DockerRollback` |
| Edge republished on deploy | ✅ shipped | `AppDeployer#republish_edge_route` |
| `deploy.yml` for all methods | ⚠️ Kamal apps only | `app/services/kamal_config.rb` |
| Candidate → health → swap → drain | ✅ shipped for `kamal_proxy` **and** `caddy`; unproxied cannot have it | `AppDeployer::ZERO_DOWNTIME_STEPS` |
| Conductor self-deploys via CI | ⚠️ CI runs, but still calls `bin/kamal` | `.github/workflows/deploy.yml` |

### What the contract unlocked

Rollback for docker apps was never hard — the release was simply being thrown
away. `docker build -t <image>:latest` followed by `docker image prune -f` meant
every build destroyed its predecessor's identity, so there was nothing to return
to. Tagging by SHA and retaining five releases made `DockerRollback` a
stop → run-the-older-tag → repoint-the-edge operation with no rebuild.

The same change hands docker apps the Kamal ops CLI: `kamal app logs`, `exec`,
and `console` locate containers by the `service` label, so labelling containers
is all that was required. The label carries the **stable resource key** (ADR
0004) rather than the slug, so a rename cannot orphan it.

## The cutover constraint (found while implementing)

Zero-downtime is not uniformly achievable, because it depends on what the edge
targets — and one case is impossible rather than merely unbuilt.

The docker path publishes a fixed host port (`-p 3000:3000`). Two containers
cannot bind the same host port, so "start the candidate alongside the old one"
means the candidate must not take that binding.

| Edge | Candidate can start alongside? | Cutover |
|---|---|---|
| `kamal_proxy` | **Yes, cleanly.** The proxy targets `container:3000` over the docker network, so the candidate needs *no host port at all* | Health-check over the docker network, then swap the proxy target. **Zero-downtime is free here.** |
| `caddy` | **Yes — shipped.** The candidate binds a second, probed-free loopback port | Health-check that port, repoint Caddy's upstream, then drain. |
| `none` / direct | **No.** The fixed host port *is* the service; nothing exists to swap | Downtime is unavoidable without introducing a proxy. |

This means the "close the outage window" work is really three pieces of differing
value, and the first is both the cheapest and covers the case that actually bit
us (Starrrs is kamal-proxy). Build in that order, and be explicit that an
unproxied app cannot have a zero-downtime deploy — that is a property of its
shape, not a missing feature.

## Related

- ADR 0001 — self-describing Kamal deploys (widened by this decision)
- ADR 0002 — Caddy as standard edge (**Rejected**; kamal-proxy stays an edge option)
- `docs/learnings/form-changes-leave-residue.md`
- `docs/learnings/deploy-lock-stranded-by-self-deploy.md`
- `docs/infra/edge-and-deploy-forms.md`
