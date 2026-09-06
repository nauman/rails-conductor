# 01. The builder

> **The decision is [ADR 0014](../dev/adr/0014-a-build-venue-is-chosen-not-inherited.md).**
> This page is how it works in practice: who decides where a build runs, what each
> venue costs, and what is still missing.

## The question this answers

"Where does this app's image get built?" — and, more usefully, *who decided that?*

Until 2026-09-06 the answer to the second question was **nobody**. Two separate
things claimed the territory:

| | What it does | What it decides |
|---|---|---|
| `BuildPlacement` | Ranks CI → `build_role` server → control machine, with the cost of each | **Nothing.** Consulted by `DeployPreflight` only |
| `KamalDeployer#deploy_env` | Sets `DOCKER_HOST` to the deploy target — *if that server has a stored SSH key* | **Everything** |

So the venue followed from credential bookkeeping. An app whose server had a key
built on that server; one whose server did not built on the control machine. Nobody
chose either, and the fleet's `build_host` column records the resulting mixture.

## The venues

**`control`** — Conductor builds where Conductor runs. No `DOCKER_HOST` is set, so
the local daemon takes the work.

- *Buys:* a bigger machine, and a build that dies cannot touch the box serving the
  app.
- *Costs:* the control machine also serves apps. A heavy build competes with them.
- *Cannot fail as a venue.* It means "build here", and Conductor is here. An earlier
  version required a registered self-managed app to name the box and refused the
  deploy without one — which is every fresh install. Naming the box is reporting;
  it is not permission.

**`target`** — the app's own server, over SSH via `DOCKER_HOST`.

- *Buys:* a warm cache on the machine that will run the image, and no pull across
  the network.
- *Costs:* the build competes with the traffic that host serves. This is the case
  `BuildPlacement` exists to discourage.
- *Can fail:* needs a reachable host with an SSH key Conductor can use.

**`NULL`** — the app predates the choice and keeps doing what it did. Not fixed, but
no longer invisible.

## No substitution

A venue that cannot take the build **fails the deploy** and names the reason. It is
never quietly relocated.

This matters more than it sounds. The substitution most likely to happen is falling
back to whatever machine is reachable — and the machine that is always reachable is
the one serving production. A fallback ladder run unattended converges on exactly
the outcome the ladder was written to prevent.

The check runs before the repo is cloned, so a policy problem does not arrive
underneath a clone failure.

## What is NOT protected yet

Moving builds onto the control machine concentrates them on a box that serves live
apps, and **nothing currently bounds their cost**:

- **No CPU ceiling.** `nice` is not the answer — it constrains the Kamal client
  while the real work happens inside daemon-managed BuildKit containers, and CPU
  shares are a relative weight rather than a limit. The control is a
  `--driver-opt cpu-quota=…` on the buildx worker, verified before each build,
  because Kamal will happily recreate an unconstrained one.
- **No lock.** Two concurrent builds are two builds' worth of contention. A
  host-wide `flock`, held from builder preparation through push, makes them queue.

Both are named in ADR 0014 as not built. Until they exist, "builds on the control
machine" means "builds on a production box with more headroom", not "builds
somewhere safe".

## Related

- [ADR 0014](../dev/adr/0014-a-build-venue-is-chosen-not-inherited.md) — the decision
- [ADR 0003](../dev/adr/0003-one-deploy-path-kamal-as-contract.md) — one deploy path
- `app/services/build_placement.rb` — the ladder, which still advises at preflight
