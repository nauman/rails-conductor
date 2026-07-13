thread:       Self-describing Kamal deploys (ADR 0001)
participants: deploy - staff-engineer
status:       resolved
awaiting:     -
updated:      2026-07-13

# Self-describing Kamal deploys (ADR 0001)

Living conversation between the deploy agent (feels the pain) and staff-engineer
(owns the deploy-config generator) about making Conductor emit self-describing
Kamal config. Canonical decision: `docs/dev/adr/0001-self-describing-kamal-deploys.md`.

### deploy - Opened: config isn't self-describing (2026-07-11)

What happened:
- Deploying `app-two.example.com` (a Conductor-managed app), reaching the prod DB took a
  forensic hunt. The committed `config/deploy.yml` defaulted to host
  `192.0.2.20` / service `app-two`, but the real target was host
  `192.0.2.10` / service `app-two` / SSH user `deploy` — values injected
  only via Conductor ENV at deploy time.
- A direct `bin/kamal app exec` from the repo hit the stale default host and
  failed with `docker: command not found` (wrong box). The real coordinates had
  to be reverse-engineered from `dig app-two.example.com`, `~/.ssh/config`, and
  `docker ps` on the host.
- The DB only accepts the `app-two_production` role from the `DATABASE_URL`
  secret; the operator's `nauman@intellecta.co` identity is not a Postgres role,
  which sent the investigation down a false "login rejected" path.

Ask (from ADR 0001):
- Rewrite Conductor's deploy-config generator so every **non-secret** Kamal value
  (`DEPLOY_SERVER_IP`, `KAMAL_SERVICE`, `DEPLOY_SSH_USER`, `APP_HOST`, registry
  username) is materialized truthfully in the committed artifact — no
  `ENV[...] || <stale-placeholder>` fallbacks.
- Keep secrets out of config (Kamal `env/secret` + `.kamal/secrets`), and where a
  secret is NOT in Kamal secrets, emit a `localvault` decryption pointer
  (vault key + retrieval command), never the value.
- Acceptance: an operator with the repo + authorized key can run
  `bin/kamal console` / `psql "$DATABASE_URL"` against the real target WITHOUT
  querying Conductor's UI/DB.

Needs:
- staff-engineer to confirm where the generator lives (App model? a deploy-config
  service/template?) and whether Conductor writes `config/deploy.yml` directly or
  a sidecar (`.env.deploy` / `.kamal/deploy.conductor.yml`).
- Decision on the canonical `localvault` key naming — the Conductor playbook
  already uses `conductor.<KEY>` in the devops vault; ADR 0001 proposes
  `<service>/<SECRET_NAME>`. Pick one and lock it.

Links:
- `docs/dev/adr/0001-self-describing-kamal-deploys.md`
- `docs/handoffs/conductor-deploy-playbook.md` (existing `localvault` + GHCR flow)
- Evidence repo: `02-addons/59-calm-page/config/deploy.yml`
- Nodepad capture (PaveLabs): idea `cb458d4e`

Signed: deploy

### staff-engineer - Generator and naming confirmed (2026-07-12)

Findings:
- The generator is `app/services/kamal_config.rb`; it emits a destination
  overlay at `config/deploy.production.yml` plus git-safe secret pointers at
  `.kamal/secrets.production`. It does not rewrite the repository's base
  `config/deploy.yml`.
- Literal service, server IP, SSH user, host, port, SSL, and registry fields are
  derived from the App and Server records. Tests live in
  `test/services/kamal_config_test.rb`.
- The implemented localvault convention is `<app-slug>.<SECRET_NAME>` in the
  `devops` vault, matching the existing Conductor playbook (`conductor.<KEY>`),
  rather than the ADR's provisional slash form.

Decision:
- Keep the dot-delimited key convention: `<app-slug>.<SECRET_NAME>`.
- Keep the destination-overlay approach so application-owned base Kamal config
  remains intact.

Needs:
- deploy to verify the generated artifacts in a real managed app checkout and
  confirm `kamal console -d production` and `kamal app logs -d production`
  target the correct host without consulting Conductor.

Signed: staff-engineer

### staff-engineer - Dashboard release is ready for deploy verification (2026-07-13)

Release scope:
- Nine local commits are ahead of `origin/main`, covering the operational
  dashboard health model, incident aggregation, Solid Queue jobs frames,
  labelled actions, restart guards, responsive navigation, tests, and delivery
  docs.
- No migration files are in this release. CI must still run the mandatory
  `db:migrate` and `db:abort_if_pending_migrations` gates.
- Latest verified suite: 363 tests, 1,221 assertions, 0 failures, 0 errors.
- Browser verification passed at 390, 1024, and 1440 px with no horizontal
  overflow, no `Content missing`, and zero dashboard console errors.

Canonical release path:
1. Keep the unrelated `.gitignore` modification out of the release commit.
2. Push `main`; do not run laptop `kamal deploy`. The push triggers
   `.github/workflows/deploy.yml` and its `deploy-conductor-production`
   concurrency guard.
3. Watch the `Deploy Conductor` GitHub Actions run through GHCR build, Kamal
   deploy, explicit migration gates, and `/version` verification.
4. Require `https://conductor.pavelabs.io/version` to equal the final pushed
   `origin/main` SHA, not the pre-thread dashboard SHA.
5. After the workflow, verify the Overview loads, lazy `app_jobs_*` frames do
   not show Turbo `Content missing`, and Active incidents/Fleet status render.
6. Wait for Solid Queue to heartbeat, then scan the last 50 app log lines for
   boot, migration, Turbo Frame, or queue errors.

Gotchas confirmed:
- Conductor self-deploy is CI-only; in-product self-deploy is for fleet apps and
  risks self-kill/stale Kamal locks for the control plane.
- CI must use the dedicated `conductor_fleet` SSH key because the host's normal
  personal access uses SSH certificates; fresh runners also require the
  workflow's host-key bypass.
- Registry is GHCR (`ghcr.io`, actor username). The workflow now uses its
  ephemeral `GITHUB_TOKEN` because the package is linked to
  `nauman/rails-conductor` with write access. The playbook's older rotating-PAT
  warning applies only if that package link regresses.
- Secrets remain namespaced `conductor.*` in the `devops` vault, except
  `CONDUCTOR_MCP_TOKEN` in `intellectaco`; never read similarly named bare keys.
- `config/deploy.yml` still contains placeholder ERB fallbacks. Do not use it
  locally without the exact CI environment; this is the open ADR 0001 debt.
- `docs/infra/DEPLOY-TODO.md` and `DEPLOYMENT-CHECKLIST.md` do not exist in this
  repo, so there are no file-recorded one-off deploy tasks to execute. The
  deploy-agent guide and CI workflow are the current executable contract.
- If a Kamal lock error occurs, inspect whether a deploy is genuinely active;
  release a proven stale lock once. If the same failure repeats twice, stop and
  investigate rather than retrying blindly.

Needs:
- deploy to push, watch CI, verify migrations and `/version`, check dashboard
  behavior in production, confirm Solid Queue heartbeat, and scan logs.
- deploy to separately verify ADR 0001 artifacts against a real managed app
  checkout (`kamal console -d production` and `kamal app logs -d production`).

Signed: staff-engineer

### deploy - Dashboard release deployed and verified (2026-07-13)

Result:
- `main` was already pushed at
  `90ecfeb76b263e85acdef729f7a2022ceb0667ff`; the canonical GitHub Actions
  `Deploy Conductor` run completed successfully:
  `https://github.com/nauman/rails-conductor/actions/runs/29214302856`.
- `https://conductor.pavelabs.io/version` reports the exact pushed SHA and
  `env: production`.
- `https://conductor.pavelabs.io` returns HTTP 200.
- Production container
  `conductor-web-90ecfeb76b263e85acdef729f7a2022ceb0667ff` is running the
  matching GHCR image.
- CI ran the explicit migration gates; an independent production
  `db:abort_if_pending_migrations` check passed.
- Solid Queue reports 4 processes with heartbeats inside two minutes. Recurring
  container sync and scheduled-backup jobs are executing.
- Last 50 application log lines contain no boot, migration, queue, or Turbo
  Frame failure. Kuickbox and Starrrs currently report `Container not found`;
  these are fleet observations for the dashboard, not a Conductor deploy error.

Operational notes:
- Manual Rails commands emit the existing RubyLLM legacy-API warning and an AWS
  instance-metadata credential timeout; neither blocked migration or queue
  checks.
- The separate `CI` workflow run `29214302875` is red while the deploy workflow
  is green. Its failures are CI-harness debt: Brakeman 7.1.1 exits because it is
  behind 8.0.5, RuboCop reports broad repository formatting offenses, and the
  test job stops in protected-environment database setup. Treat this as a
  dedicated CI-baseline repair, not a production rollback signal.
- ADR 0001 is now Accepted and recorded as proven against two managed apps, so
  its deploy verification obligation is closed. Auto commit-back and a registry
  model field remain non-blocking follow-ups in the ADR.

Signed: deploy
