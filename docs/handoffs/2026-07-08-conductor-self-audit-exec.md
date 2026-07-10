# Conductor Self-Audit — Exec Summary (for diff vs Codex)

**2026-07-08 · Conductor agent (Claude).** Full report: `2026-07-08-conductor-self-audit.md`.

## Verdict
Conductor deploys the fleet reliably **through its own UI/CI** (all live: conductor.pavelabs.io, kuickr.co, calm.page, wiseherds.com) — but it **breaks the standard Kamal 2 developer experience** it was supposed to deliver. **Overall: C+.**

## The founder's actual pain (the real symptom)
You chose Kamal 2 for its DX. From a Conductor-managed repo, that DX does not work:
- `kamal logs` → connects to the placeholder `host: "YOUR_SERVER_IP"` and fails.
- `kamal app exec --reuse "bin/rails console"` → can't reach the real box; "hell."
- `kamal dbc` / `psql "$DATABASE_URL"` → no reproducible local secret bridge; localvault may hold it, but the repo does not clearly say which vault/key to unlock or seed into `.kamal/secrets*`.
- Result: **Conductor made Kamal worse than vanilla Kamal** — you got the deploy, lost the console/logs/shell.

## Root cause (one thing)
Conductor injects the real coordinates (`DEPLOY_SERVER_IP`, `APP_HOST`, registry, and sometimes app-provided `KAMAL_SERVICE`) as **ENV at deploy time**, and the committed `config/deploy.yml` is generic ERB with `ENV[...] || "<placeholder>"`. Truth lives only in Conductor's DB/process. Outside that process the placeholders win. **Smoking gun:** Conductor's *own* deploy.yml → `host || "YOUR_SERVER_IP"`, `registry || "docker.io"` (fleet is really ghcr.io). calm.page proved the cost (defaulted to wrong host `91.107.218.170`/`mademysite` vs real `135.181.114.59`/`calmpage`).

## Kamal 2 correction (Codex research)
Kamal 2 expects `config/deploy.yml` (plus optional `config/deploy.<destination>.yml`) to describe the deployment, and `.kamal/secrets*` to resolve secrets. **Secrets are not loaded into `deploy.yml` ERB.** Therefore the fix is not "put secrets in deploy.yml"; it is:
- commit/generate real non-secret topology in Kamal config or destination config;
- keep raw secrets out of git;
- make `.kamal/secrets*` either a safe localvault/password-manager pointer or a gitignored locally-seeded file;
- ensure the repo tells the operator exactly which localvault vault/key to unlock when secrets are missing.

## Kamal 2 expects vs what Conductor does
| Kamal 2 convention | Conductor today |
|---|---|
| `config/deploy.yml` / `deploy.<destination>.yml` = real deploy topology | placeholder ERB; truth in Conductor's DB/process |
| `.kamal/secrets*` resolves secrets (ENV / secret helpers) | transient Conductor checkout file or unclear local bridge |
| repo is self-sufficient → `logs/console/shell/dbc` work | works only *through* Conductor; broken by hand |
| localvault/password manager = explicit secret source | positioned as ambient/ad-hoc; missing vault/key breadcrumb |

## Top 3 fixes (priority)
1. **P0 — Kamal-native self-describing deploys (ADR 0001):** generate real non-secret config (`config/deploy.yml` or `config/deploy.production.yml`) + a secret bridge (`.kamal/secrets.production` with safe localvault pointers, or gitignored locally-seeded values). Acceptance test: `kamal console -d production` / `kamal logs -d production` / DB console work from the repo with Conductor offline.
2. **P0 — Gate migrations for fleet apps** (generalize Conductor's CI `db:migrate` + `abort_if_pending`; 2 prod 500s came from this).
3. **P1 — One secret source of truth** + retire self-deploy-in-container for fleet apps (slots 23/25).

## Cross-check instruction for Claude
Re-run this audit against primary Kamal 2 sources before finalizing: official docs (`kamal-deploy.org/docs/installation/`, configuration, environment variables, secrets changes, aliases/app exec) and the local PDF handbook at `/Users/naumantariq/Downloads/Kamal Handbook_ The missing manual -- Josef Strzibny -- null, null, 2024 -- null -- 6d396b841790b14953f0b8e4aacea886 -- Anna’s Archive.pdf`.

## Where auditors will likely disagree
- Severity of F1 (cosmetic-config vs P0 DX/DR failure — this audit says P0).
- Whether F2's move to CI is "fixed" or merely relocated (fleet apps still self-deploy in-container).
