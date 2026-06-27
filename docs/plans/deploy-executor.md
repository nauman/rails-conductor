# Deploy Executor Plan

> Roadmap slot 23 (`docs/roadmap/23-deploy-executor.html`). Source handoff:
> "UI deploy architecture" (2026-06-24), filed in the PaveLabs nodepad → Agents → Handoff
> (`inventlist np export n8gpxc4vkg`).

## Pillar
Runtime backends

## Status
Active — architecture rework, P1, effort L

## Current Reality

- `DeployAppJob` selects a deployer by `app.deploy_method` (`native` → `NativeDeployer`,
  `kamal` → `KamalDeployer`, else `AppDeployer`) and calls `deploy!` **in-process**.
- Jobs run inside the long-lived **web container** (`SOLID_QUEUE_IN_PUMA`), which for a
  self-managed app is **itself a deploy target**. `kamal deploy` stops the old container
  mid-swap → the job is SIGTERM'd before `deployment.succeed!`.
- Workarounds in place and working, but fragile:
  - `SelfDeployReconciler` finalizes a stranded self-deploy on the **new** release's boot
    by matching `deployment.commit_sha` against `KAMAL_VERSION`.
  - `KamalDeployer#materialize_master_key` + committed-`.kamal/secrets` reuse for self-deploys.
  - `KamalDeployer` rebuilds `.kamal/secrets` from `EnvVariables` (`KamalEnvWriter`) for
    every non-self app.
  - Build-over-SSH (`DOCKER_HOST=ssh://…`) requires seeding the real `~/.ssh`
    (`setup_ssh_home`, `seed_known_hosts`) because ssh resolves `~` from passwd, not `$HOME`.
- Deploy progress is **streamed to stdout / ActionCable** and only persisted as a single
  appended `log` text column. If the runner dies, in-flight structured state is lost — the
  "log says streaming but isn't" failure.

## Goal

Stop running `kamal` (and eventually all deployers) inside the long-lived web container.
Move each deploy into a **short-lived, isolated executor** spawned per deploy, so:

- a **self-deploy** completes and records success **without** a reconciler (the executor
  outlives the web container's restart);
- **secrets are injected at spawn** (or vault-resolved), never rebuilt from the DB or
  written to a long-lived file;
- each run is **stateless** — no accumulated SSH/workspace cruft in the web container.

## Guiding Principle

**The web app holds NO in-flight deploy state — Postgres does.** The one-off container is
only the means. (Grounded in ubicloud: work is a DB row run by a stateless worker, mutual
exclusion is a DB lease, secrets are pulled per-operation and never persisted.)

## Scope

- A `DeployRunner` boundary that all deployers (kamal first, then docker + native) sit behind.
- A per-app **deploy lease** for one-at-a-time execution + crash recovery.
- A `conductor-deployer` container image (kamal + docker CLI + git) and a Solid Queue job
  that spawns + supervises it as a one-off container on the host daemon.
- **Structured deploy progress persisted to the `Deployment` row** (phase + status),
  not just streamed stdout; final status taken from the **executor's exit code**, not the
  web job's lifecycle.
- Secret injection at spawn (env now; vault-resolved via slot 16 later); deletion of the
  DB→`.kamal/secrets` rebuild path.
- Check-then-act phases so a crashed/torn deploy is safely re-runnable.

## Non-goals

- Building ubicloud's custom scheduler — reuse **Solid Queue** (already present).
- A general container-orchestration layer beyond what deploy execution needs.
- Replacing Caddy routing or adopting `kamal-proxy` (see `deployment-kamal.md`).
- Multi-instance / rolling / blue-green deploy orchestration (deferred).
- Full secretless deploys — that's slot 16; this plan only makes injection-at-spawn the seam.

## Core Workflows

1. Operator triggers a deploy (UI or MCP). The web app writes a `Deployment` row and
   enqueues a supervisor job — it does **not** run `kamal`.
2. The supervisor acquires the app's deploy lease, spawns the `conductor-deployer`
   container with repo ref + injected secrets, and supervises it.
3. The executor runs the deploy, **writing structured phase/status back to the `Deployment`
   row** as it goes (not only streamed stdout), and exits with a status code.
4. Final deployment status is derived from the executor's exit; a crashed executor's lease
   expires and the deploy is reclaimable/retryable. Self-deploy needs no reconciler.

## Architecture: control plane vs. executor

- **Control plane** = the Conductor web app. Stores config, shows UI, exposes MCP.
  **Never** runs `kamal` in-process.
- **Deploy executor** = short-lived runner spawned per deploy — `docker run --rm
  conductor-deployer …` on the host daemon (or a dedicated worker) — given repo, env, and
  secrets at spawn, runs `kamal deploy`, exits.

## Implementation Slices

1. **Runner boundary + lease + image.** Extract a `DeployRunner` seam (the web app talks to
   this, not to `KamalDeployer` directly). Add a **deploy lease** on the app (one deploy at a
   time; a crashed/expired lease is reclaimable — model on `FOR NO KEY UPDATE SKIP LOCKED` +
   a lease timestamp). Package a `conductor-deployer` image (kamal + docker CLI + git).
2. **Spawn + supervise + DB-persisted progress.** A Solid Queue job spawns the executor as a
   one-off container per deploy on the host daemon and supervises it. **Persist structured
   progress to the `Deployment` row** (a `phase` + status, beyond the `log` text); final
   status from the executor's **exit code**, not the web job.
3. **Inject secrets at spawn + check-then-act.** Inject secrets at spawn (env now,
   vault-resolved later); delete the DB→`.kamal/secrets` rebuild path
   (`write_secrets_file` / `KamalEnvWriter` for deploy). Make each phase check-then-act so a
   crashed deploy is safely re-runnable. Self-deploy needs **no** reconciler.
4. **Retire workarounds + unify backends.** Retire `SelfDeployReconciler` (or keep as
   belt-and-suspenders behind a flag). Migrate `AppDeployer` (docker) and `NativeDeployer`
   onto the same `DeployRunner` boundary so all three share lease + persisted progress.

## Pitfall

**Re-entry ≠ idempotency.** `kamal deploy` mid-swap is **not** idempotent — blindly retrying
a torn deploy can double-act. Each phase must be check-then-act; decide per-phase whether to
resume, roll back, or require a human.

**Novel to us:** none of the prior art (kamal-ui, polaris-deploy, ubicloud) ever redeploys
the process orchestrating the deploy. The **self-deploy / bootstrap-swap** problem is ours
alone, and externalizing the executor is the correct answer.

## Requirements

1. The web app never runs `kamal` in-process; deploys run in a spawned executor.
2. Deploy state lives in Postgres — phase + status on the `Deployment` row, not stdout.
3. One deploy per app at a time via a lease; a crashed lease expires and is reclaimable.
4. Final status is the executor's exit code, independent of the web job's lifecycle.
5. Secrets are injected at spawn (or vault-resolved), never rebuilt from the DB or persisted.
6. Each phase is check-then-act so a torn deploy is safely re-runnable.
7. All three backends (kamal, docker, native) share the same `DeployRunner` boundary.

## Acceptance Criteria

- A self-deploy completes and records success **without** a reconciler — the executor
  survives the web container's restart.
- No deploy rebuilds `.kamal/secrets` from the DB; secrets are injected at spawn (or
  vault-resolved) and never persisted.
- Each deploy runs in a fresh, stateless executor; no accumulated SSH/workspace state in the
  web container.
- A crashed executor doesn't strand a deploy: its lease expires, the deploy is
  reclaimable/retryable, and status reflects DB-persisted progress (not lost stdout).

## Milestones

1. `DeployRunner` boundary + deploy lease landed; `conductor-deployer` image builds.
2. Solid Queue supervisor spawns + supervises the executor; progress persisted to the row.
3. Secret injection at spawn replaces the `.kamal/secrets` rebuild; check-then-act phases.
4. Self-deploy green without the reconciler; docker + native migrated onto the runner.

## Risks

- **Docker socket exposure** — the executor needs the host daemon; constrain it (least
  privilege, short-lived, no inbound).
- **Lease correctness** — a buggy lease either serializes nothing or wedges deploys forever;
  needs a watchdog + expiry, tested under crash.
- **Partial-deploy ambiguity** — distinguishing "still building" from "torn mid-swap"
  without the reconciler's `KAMAL_VERSION` signal; the per-phase DB state must carry enough
  to decide.
- **Migration risk** — moving the working (if fragile) in-process path off the critical
  deploy route; keep the old path behind a flag until the executor is proven.

## Dependencies

- Supersedes the workarounds in `docs/plans/conductor-phase-3-deployment.md` +
  `SelfDeployReconciler`.
- Pairs with secretless deploys (roadmap slot 16) for the secret-injection seam.
- `docs/plans/deployment-kamal.md` (backend abstraction context).
- Solid Queue (present), the `conductor-deployer` image, host docker daemon access.

## Decisions

- Reuse Solid Queue to spawn + supervise; do **not** build a custom scheduler.
- Externalize the executor rather than keep patching the in-process self-deploy path.
- Keep secrets out of the executor's persisted state entirely; injection-at-spawn is the
  seam that slot 16 later makes vault-resolved.
- Kamal migrates first (it has the most acute self-deploy pain); docker + native follow onto
  the same boundary.
