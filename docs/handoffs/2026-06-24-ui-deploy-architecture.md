# Handoff — UI deploy architecture (deploying Conductor through Conductor)

**Date:** 2026-06-24 · **Status:** deploy works, but the architecture is suspect and needs a rethink.

## What we were doing
Deploying the **Conductor app itself** from Conductor's own UI/MCP. The mechanism (`KamalDeployer`) makes **Conductor's container the Kamal control machine**: it clones the repo into a workspace, regenerates `.kamal/secrets`, sets up SSH, and runs `kamal deploy` as a subprocess — building on the target's docker daemon over SSH (`DOCKER_HOST=ssh://…`).

## How it went (the failure chain — all now fixed/worked-around)
1. Deploy method was **Docker**, not Kamal → phantom `conductor-conductor` container reported green but didn't serve. Fixed: set method = Kamal.
2. **Self-deploy kills its own job** — `kamal deploy` stops the old container (where `DeployAppJob` runs) mid-swap → job dies before recording success → UI shows "failed" though it worked. Worked around with `SelfDeployReconciler` (reconcile on the new release's boot via `KAMAL_VERSION`).
3. **Missing secret env vars** — `KamalDeployer` rebuilds `.kamal/secrets` from the app's EnvVariables; the Conductor app had none → empty `docker login -p`, missing `config/master.key`. Fixed: set the full secret set on the app.
4. **Wrong registry** — fleet moved to **GHCR** (off Docker Hub, 2026-06-18); `KAMAL_REGISTRY_SERVER`/`USERNAME` defaulted to docker.io/your-user. Fixed: set `ghcr.io` + `nauman`.
5. **Bad registry token** — `KAMAL_REGISTRY_PASSWORD` needs GHCR `write:packages`. Fixed: used the `gh auth token` (has the scope), stored in devops vault.

✅ Result: deploy went green; all of this session's code is live on `conductor.pavelabs.io`.

## Why the architecture is suspect (the real point)
Kamal is a **client-side / CI tool** — designed to run from a laptop or CI job, orchestrating *remote* servers. Conductor runs `kamal deploy` from **inside a long-lived app container that is itself one of those deploy targets**. That inversion causes everything above:

1. **Self-reference / bootstrap** — Conductor deploying Conductor means the deployer kills itself mid-swap. The reconciler is a band-aid over a structural problem.
2. **Secret re-plumbing** — kamal expects secrets in the runner's env; the runner (Conductor's container) doesn't have the deploy-time secrets, so we rebuild `.kamal/secrets` from DB env vars. The entire secret-juggling saga stems from this.
3. **docker-over-SSH complexity** — the container can't build locally cleanly, so it builds on the target daemon over SSH (host keys, `known_hosts`, the stale `conductor_kuickr` identity, etc.).
4. **Multi-tenant runner confusion** — one long-lived container running deploys for many apps accumulates SSH/identity/workspace state.

## Proposed better architecture (to evaluate)
Separate **control plane** from **deploy executor**:
- **Control plane** = the Conductor web app — stores config, shows UI, exposes MCP. Never runs `kamal` in-process.
- **Deploy executor** = a **short-lived, isolated runner per deploy** — a one-off container (`docker run --rm conductor-deployer …`) or a dedicated host worker, spawned with the right env/secrets, that runs `kamal deploy` and exits. This:
  - survives the web container's restart (fixes self-deploy without a reconciler),
  - gets secrets injected at spawn (no `.kamal/secrets` rebuild from the DB),
  - is stateless (no accumulated SSH/workspace cruft).
- Keep secrets out of it entirely via **secretless / vault-resolved** deploys (roadmap 16).

## Prior art to study (references the user gave)
- **kamal-ui** (github.com/ronaldlangeveld/kamal-ui) — a UI wrapper over the kamal CLI; look at how it invokes/isolates kamal.
- **polaris-deploy.com** — managed kamal deploys; their executor model.
- **ubicloud** (github.com/ubicloud/ubicloud) — open-source cloud/PaaS on bare metal; control-plane vs. executor separation at scale.
- **sessy** (github.com/marckohlbrugge/sessy, local `00-source/05-sessy-ses-ui-log`) — SES email observability; the model for roadmap slot 20's "monitor SES" half.

## Open questions for next session
1. Runner model: one-off container per deploy vs. a persistent deploy-worker (separate from web)?
2. Where do secrets live at deploy time — injected into the runner, or vault-resolved (slot 16)?
3. Do we keep "Conductor = control machine," or move to "Conductor orchestrates an isolated kamal runner"?
4. How do kamal-ui / polaris solve the same problem?

## Heroku-DX goal (related, separate thread)
Surface kamal's dev affordances (already aliased in `deploy.yml`: `logs`, `console`, `shell`, `dbc`) in the **UI + MCP**, with **runtime-agnostic parity** so the same "logs / console / run task / restart" works for Kamal *and* Native (journalctl + `bin/rails` over SSH). Roadmap: slot 09 (in-container task runner) + slot 11 (web console) + slot 06 (logs, done). This is the "another Heroku" experience.
