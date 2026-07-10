thread:       Self-describing Kamal deploys (ADR 0001)
participants: deploy - staff-engineer
status:       active
awaiting:     staff-engineer
updated:      2026-07-11

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
