# Conductor Deploy Playbook

**Canonical deploy: GitHub Actions CI.** Push to `main` → build → push image to GHCR → `kamal deploy` over SSH → migrate → verify `/version`. Self-deploy via the UI is for OTHER fleet apps; the backbone goes through CI.

_Last updated 2026-06-28. Internal ops — keep out of the public repo._

## TL;DR — how to deploy
```bash
git push origin main            # auto-deploys via .github/workflows/deploy.yml
# or trigger manually:
gh workflow run "Deploy Conductor" -R nauman/rails-conductor
gh run watch -R nauman/rails-conductor
# verify (must match origin/main HEAD):
curl -s https://conductor.pavelabs.io/version
```

## The workflow (`.github/workflows/deploy.yml`)
Triggers on push to `main` + `workflow_dispatch`. Concurrency-guarded (`deploy-conductor-production`, no cancel) so two deploys never contend for the kamal lock. Steps: checkout → setup-ruby → buildx → materialize `config/master.key` from secret → (in one step) write `~/.ssh/config` host-key bypass + load SSH key into ssh-agent + `bin/kamal deploy` + `bin/rails db:migrate` + `db:abort_if_pending_migrations` → verify `/version`.

## Required GitHub config (Settings → Secrets and variables → Actions)
**Variables:** `DEPLOY_SERVER_IP=135.181.114.59` · `DEPLOY_SSH_USER=deploy` · `APP_HOST=conductor.pavelabs.io`

**Secrets** (where each comes from):
| Secret | Source |
|---|---|
| `SSH_PRIVATE_KEY` | `~/.ssh/conductor_fleet` (dedicated fleet key, already authorized on the box) |
| `RAILS_MASTER_KEY` | local `config/master.key` |
| `KAMAL_REGISTRY_PASSWORD` | a token that OWNS the ghcr package (currently `gh auth token`) |
| `DATABASE_PASSWORD`, `ACTIVE_RECORD_ENCRYPTION_{PRIMARY,DETERMINISTIC}_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`, `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD` | **devops vault, namespaced `conductor.*`** (e.g. `conductor.DATABASE_PASSWORD`) |
| `CONDUCTOR_MCP_TOKEN` | **intellectaco vault**, key `conductor.CONDUCTOR_MCP_TOKEN` |
| `SENTRY_DSN` | optional (blank ok) |

Set vault secrets cleanly (value never printed): `localvault unlock devops && localvault get conductor.X --vault devops | gh secret set X -R nauman/rails-conductor`.

## The 5 hard-won gotchas (all solved 2026-06-27)
1. **GHCR push 403 with the Actions `GITHUB_TOKEN`** — the `ghcr.io/nauman/conductor` package was created out-of-band and isn't linked to the repo, so the Actions token can't write it. Workaround: `KAMAL_REGISTRY_PASSWORD` = a token that OWNS the package. ⚠️ The `gho_` gh token rotates with the gh session → CI 403s again → re-set the secret. **Durable fix:** GitHub → your packages → `conductor` → **Package settings → Manage Actions access → add `rails-conductor` (Write)**, then revert the workflow's `KAMAL_REGISTRY_PASSWORD` to `${{ secrets.GITHUB_TOKEN }}` (never rotates). Or a dedicated `write:packages` classic PAT.
2. **The box uses SSH CERTIFICATE auth** (CA-trusted), not plain `authorized_keys`. A personal key's raw pubkey isn't authorized (auth fails) even though it works locally via its cert. CI must use a key that's in `authorized_keys` directly → the dedicated **`conductor_fleet`** key (it is). Workflow loads it into an ssh-agent in the deploy step + the pinned host key from the `DEPLOY_KNOWN_HOSTS` variable (ssh-keyscan output) with `StrictHostKeyChecking yes` — it fails closed if the pin is missing (never `StrictHostKeyChecking no`).
3. **Vault secrets are namespaced `conductor.*`** in devops — NOT bare names. Reading bare `DATABASE_PASSWORD` may grab a different/stale value. Always use `conductor.<KEY>`.
4. **Registry config (`KAMAL_REGISTRY_SERVER=ghcr.io`, `KAMAL_REGISTRY_USERNAME=nauman`)** is set in the workflow env (the fleet moved off Docker Hub to GHCR, 2026-06-18). Without it, kamal defaults to `docker.io`/`your-user` → "incorrect username or password".
5. **Migrations** — the image entrypoint runs `db:prepare` on boot, but the CI now ALSO runs `db:migrate` + `db:abort_if_pending_migrations` as an explicit, fail-loud, gated step. A failed migration now fails the deploy instead of leaving prod's DB lagging the code (the recurring 500 root cause).

## Verify a deploy
`/version` returns `{app, version, env}` where `version` = the deployed git sha. A deploy is live when `curl conductor.pavelabs.io/version` matches `git rev-parse HEAD` on `origin/main`. (Pre-deploy, old code without the endpoint returns 404.)

## Troubleshooting map (symptom → cause)
- **`docker login -p` empty / 401** → `KAMAL_REGISTRY_PASSWORD` missing.
- **`incorrect username or password`** → `KAMAL_REGISTRY_SERVER`/`USERNAME` not set (defaulting to docker.io).
- **`403 Forbidden` pushing to ghcr** → package not linked to repo (gotcha 1).
- **`HostKeyMismatch`** → the box's key changed or the `DEPLOY_KNOWN_HOSTS` pin is stale → re-run `ssh-keyscan -H <ip>` and update the variable (do NOT disable host checking).
- **`Authentication failed for user deploy`** → wrong/unauthorized SSH key → use `conductor_fleet`.
- **`Deploy lock found`** → stale lock from a killed self-deploy → `kamal lock release` (CI's concurrency guard prevents new ones; self-deploy auto-releases since commit 7e6011f).
- **prod 500s after deploy** → check migrations ran (now gated in CI).

## Related
- Architecture: `2026-06-24-ui-deploy-architecture.md` (why CI, not self-deploy) + roadmap slot 23.
- Self-deploy mechanics (for fleet apps): roadmap slot 01, `SelfDeployReconciler`.
- Secretless future: roadmap slot 16.
