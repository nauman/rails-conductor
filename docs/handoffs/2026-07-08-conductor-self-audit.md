# Conductor Self-Audit — Deploy & Fleet Architecture

**Date:** 2026-07-08 · **Auditor:** Conductor agent (Claude) · **Method:** live-fleet probing + source review, not aspiration. Cross-check pending (Codex + Kamal 2 primary docs/PDF).
_Internal ops — references real infra (IPs, vaults). Keep out of the public repo._

## TL;DR

Conductor **reliably deploys the fleet through its own UI/CI happy-path** — all live apps are up. But it does so by a mechanism that **violates "reproducible by hand"**: real deploy coordinates live only in Conductor's DB/process and are injected as ENV at deploy time, while the committed `config/deploy.yml` carries misleading placeholder defaults. Running `bin/kamal` from any managed repo targets the wrong host unless the same out-of-band env is reconstructed. **Kamal support is ~60%: it deploys, but not the first-class standard way.** The control plane's self-management was fragile (now moved to CI). Grade: **C+ / works-but-owes-a-refactor.**

## Live fleet snapshot (verified 2026-07-08)

| App | Domain | HTTP | Deploy path today | Runtime | `bin/kamal` from repo works? |
|---|---|---|---|---|---|
| Conductor | conductor.pavelabs.io | 200 (`/version` = 9ceab59) | **GitHub Actions CI** (moved off self-deploy) | Kamal, fleet box | ❌ deploy.yml → `YOUR_SERVER_IP` / `docker.io` |
| Kuickr | kuickr.co | 200 | Conductor self-deploy (KamalDeployer as control machine) | Kamal, fleet box | ❌ ENV-injected coords only |
| Calm.page | calm.page | 200 | Conductor-managed Kamal | Kamal, fleet box | ❌ **incident** — defaulted to wrong host/service |
| Wiseherds | wiseherds.com | 200 | Conductor-managed Kamal | Kamal, fleet box | ❌ same pattern |
| intellectaco / agpages-2 / minimalnarrow | — | (Hatchbox box 89.233.107.200) | **Hatchbox**, NOT Conductor | Native systemd `--user` units (`<app>-server`) | n/a (different tool) |

Fleet box: `135.181.114.59` (Kamal + shared `conductor-postgres`). Hatchbox box: `89.233.107.200` (native, root=automation / deploy=apps).

## How deploys actually work (the mechanism)

Conductor is the Kamal **control machine**: `KamalDeployer` clones the app repo, sets `deploy_env` from the App record (`DEPLOY_SERVER_IP ||= app.server.ip_address`, `APP_HOST`, registry values; `KAMAL_SERVICE` only if supplied as an app env var), then runs `kamal deploy` as a subprocess. The app's committed `config/deploy.yml` is generic ERB: `<%= ENV["X"] || "<placeholder>" %>`. Secrets are checked via `ENV[key].present?` and written to `.kamal/secrets` in Conductor's transient checkout at deploy time.

**The load-bearing assumption:** the real values exist *in Conductor's process env*. Outside that process, the placeholders win.

## Kamal 2 research correction (Codex)

Codex cross-checked the claim against the official Kamal 2 docs and the local handbook PDF. The corrected model:

- Kamal reads deployment topology from `config/deploy.yml`, optionally merged with `config/deploy.<destination>.yml`.
- `.kamal/secrets`, `.kamal/secrets-common`, and `.kamal/secrets.<destination>` are dotenv-style secret sources used by Kamal commands.
- Kamal 2 does **not** load `.kamal/secrets` into `deploy.yml` ERB. If `deploy.yml` uses `ENV[...]`, those variables must already be in the command environment or be explicitly loaded by the config (for example via dotenv).
- `kamal app exec`, `kamal app logs`, and aliases like `kamal console` are standard Kamal DX. A Conductor-managed repo should preserve them.

Implication: ADR 0001 should be phrased as **Kamal-native self-describing deploys**, not "put everything in deploy.yml." The repo needs real non-secret topology in Kamal config/destination config, and a safe secret bridge in `.kamal/secrets*`: either localvault/password-manager commands or a gitignored local file seeded once from localvault. Raw secrets never go in git.

If localvault remains the source, the repo must at least know what to ask for:

```sh
# .kamal/secrets.production (git-safe only if it contains commands, not values)
# Requires: localvault unlock <vault>
DATABASE_URL=$(localvault get <app>.DATABASE_URL --vault <vault>)
KAMAL_REGISTRY_PASSWORD=$(localvault get <app>.KAMAL_REGISTRY_PASSWORD --vault <vault>)
RAILS_MASTER_KEY=$(localvault get <app>.RAILS_MASTER_KEY --vault <vault>)
```

Alternative: commit `.kamal/secrets.production.example`, keep real `.kamal/secrets.production` ignored, and provide a setup command that seeds it once from localvault so day-to-day `kamal logs/console/dbc` does not repeatedly ask for vault access.

## Findings

### F1 — The truth-gap (P0). Real coordinates live only in Conductor's DB.
The committed config actively misleads. **Evidence, Conductor's own `config/deploy.yml`:**
```erb
host:     <%= ENV["DEPLOY_SERVER_IP"] || "YOUR_SERVER_IP" %>
registry: <%= ENV["KAMAL_REGISTRY_SERVER"] || "docker.io" %>   # fleet is really ghcr.io
```
**calm.page incident (the ADR evidence):** committed defaults were host `91.107.218.170` / service `mademysite`; real prod is `135.181.114.59` / `calmpage`. A hand-run `bin/kamal app exec` hit the stale host → `docker: command not found`; finding the prod DB took a forensic hunt across `dig`, `~/.ssh/config`, and container enumeration.
**This is the norm, not an outlier** — every Conductor-managed repo (Conductor included) ships these placeholders.
→ Fix: **ADR 0001, Kamal-native self-describing deploys** (Proposed, parked). Write real non-secret topology into `config/deploy.yml` or `config/deploy.production.yml`, and add a `.kamal/secrets*` bridge that either points to localvault/password-manager commands or is seeded locally into a gitignored file. `bin/kamal console -d production`, `bin/kamal app logs -d production`, and DB console must work from the repo with Conductor offline.

### F2 — Self-deploy inversion (was P0, mitigated). Control plane deploying itself.
Running `kamal deploy` *inside* the long-lived container that is *also* a deploy target → self-kill mid-swap, stranded locks. **Evidence:** the multi-hour Conductor self-deploy saga this session; kuickr deployment #60 died on `Kamal::Cli::LockError` with a stale lock that blocked all further deploys until manual `kamal lock release`.
→ Fixed: Conductor now deploys via **GitHub Actions CI** (clean control machine). Fleet apps still self-deploy through Conductor's container. Deploy serialization (unique partial index) + auto-lock-release shipped. Full isolation = **slot 23** (deploy-executor rework), not done.

### F3 — Secrets scattered across 3+ homes (P1). No single source of truth.
Secrets live in: Conductor DB (`app.env_variables`), localvault vaults (`devops`/`intellectaco`, namespaced `conductor.*`), `.kamal/secrets`, and now GHA secrets. **Evidence:** wiring Conductor's CI required pulling 6 secrets from `devops` (`conductor.DATABASE_PASSWORD`…), the MCP token from `intellectaco` (`conductor.CONDUCTOR_MCP_TOKEN`), and the master key from a local file — three different homes for one app. The Kamal-native fix is not to commit secret values; it is to commit safe secret pointers or a setup command that knows exactly which localvault vault/key to seed into a gitignored `.kamal/secrets*` file.

### F4 — Migrations not gated for fleet apps (P0). "DB lags code."
Fleet deploys rely on the image entrypoint's silent `db:prepare`. **Evidence:** two prod 500s from code shipping ahead of schema.
→ Fixed for **Conductor's own CI** (gated `db:migrate` + `db:abort_if_pending_migrations`). **NOT yet generalized to `KamalDeployer`** for fleet apps = **slot 24**.

### F5 — Mixed-runtime reality only partly modeled (P1).
The Hatchbox box (intellectaco/agpages-2/minimalnarrow) runs native `--user` systemd apps with a root=automation / deploy=apps split — and **isn't managed by Conductor at all**. Conductor's native log tail was silently broken there (fixed this session: `XDG_RUNTIME_DIR` for non-login SSH). Two-identity server model = **slot 25**, not built.

## Fixed this session (evidence of direction)
CI self-deploy for Conductor · gated migrations (Conductor) · deploy serialization + auto-lock-release · native log tail fix · reactive fleet statuses · server health + install-packages · `/version` verifiability · ADR 0001 recorded.

## Open gaps, prioritized
1. **P0 — Kamal-native self-describing deploys (ADR 0001).** `bin/kamal` broken from every managed repo unless out-of-band Conductor env is reconstructed. The headline debt.
2. **P0 — Gate migrations for fleet apps** (generalize the CI pattern into `KamalDeployer`).
3. **P1 — Single secret source of truth**; localvault = explicit source/pointer or setup-time seed, `.kamal/secrets*` stays git-safe or gitignored.
4. **P1 — Deploy-executor isolation** (slot 23) — retire self-deploy-in-container for fleet apps too.
5. **P1 — Two-identity servers** (slot 25) + adopt the Hatchbox box into Conductor.

## Required follow-up for Claude

Before revising ADR 0001 or implementing a fix, Claude must use the original Kamal 2 sources, not memory:

- Official docs: `https://kamal-deploy.org/docs/installation/`, configuration overview, environment variables, secrets changes, aliases, and `kamal app exec/logs`.
- Local PDF: `/Users/naumantariq/Downloads/Kamal Handbook_ The missing manual -- Josef Strzibny -- null, null, 2024 -- null -- 6d396b841790b14953f0b8e4aacea886 -- Anna’s Archive.pdf`.
- Acceptance test must be from the app repo with Conductor offline: `kamal app logs -d production`, `kamal console -d production` (or alias equivalent), and DB console / `psql "$DATABASE_URL"` with secrets resolved through the documented `.kamal/secrets*` path.

## Honest grade
- **Reliability (through Conductor):** B — the fleet is up; serialization + auto-lock-release + CI closed the worst failure modes.
- **Kamal first-class support:** C — deploys, but violates the standard "repo is the source of truth"; `bin/kamal` from a repo fails everywhere.
- **Operability by hand / DR:** D — recovering an app without Conductor online is a forensic exercise (calm.page proved it).
- **Overall:** **C+** — a working control plane carrying one large, well-understood architectural debt (F1/ADR 0001), now documented and parked rather than hidden.
