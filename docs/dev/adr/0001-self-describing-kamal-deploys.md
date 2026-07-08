# 0001. Self-describing Kamal deploys — config carries everything non-secret

Date: 2026-07-08

## Status

Proposed

## Context

Conductor deploys apps via Kamal by injecting deploy-time ENV
(`DEPLOY_SERVER_IP`, `KAMAL_SERVICE`, `DEPLOY_SSH_USER`, `APP_HOST`,
`KAMAL_REGISTRY_USERNAME`) from the App record into a generic `config/deploy.yml`
that the app repo commits. The committed config uses `ENV[...] || <default>`
fallbacks so the repo still "runs" without Conductor.

This creates a **truth gap**: the values committed in the repo are placeholders,
and the real deploy target lives only in Conductor's database and is materialized
transiently at deploy time. An operator reading the repo — or running
`bin/kamal` directly from it — is actively misled.

Concrete incident (calm.page / MadeMySite, 2026-07-08):

- Committed `config/deploy.yml` defaulted to host `91.107.218.170` and service
  `mademysite`.
- Real production was host `135.181.114.59`, service `calmpage`, SSH user
  `deploy` (key `~/.ssh/pavelabs_deploy`), Postgres in a shared
  `conductor-postgres` accessory — all injected only via Conductor ENV.
- A direct `bin/kamal app exec` from the repo hit the stale default host and
  failed with `docker: command not found` (that host has no Docker).
- Finding the production database required reverse-engineering DNS
  (`dig calm.page`), scanning `~/.ssh/config`, and enumerating containers by
  hand. The operator's identity (`nauman@intellecta.co`) was never a Postgres
  role — the DB only accepts `calmpage_production` from the `DATABASE_URL`
  secret — so "login rejected" sent the investigation down a false path.

The DB password / secrets handling is correct (Kamal `env/secret` +
`.kamal/secrets`, pulled from ENV / a password manager). The defect is that
**non-secret** deploy coordinates are hidden behind misleading defaults instead
of being written out truthfully.

## Decision

When Conductor manages a Kamal deploy, it MUST emit a **self-describing** deploy
artifact. Rules:

1. **Every non-secret Kamal value is materialized in-repo, truthfully.** The
   generated `config/deploy.yml` (or a Conductor-written
   `.kamal/deploy.conductor.yml` / `.env.deploy` committed alongside it) carries
   the *actual* `DEPLOY_SERVER_IP`, `KAMAL_SERVICE`, `DEPLOY_SSH_USER`,
   `APP_HOST`, and registry username for that App — not `|| <placeholder>`
   fallbacks. A stale default that points at the wrong host is a bug, not a
   convenience.

2. **Secrets never live in config.** Passwords, master keys, and
   `*_DATABASE_URL` stay in Kamal secrets (`env/secret` referencing
   `.kamal/secrets`), sourced from ENV or a password manager. `.kamal/secrets`
   stays git-safe (no raw values).

3. **Where a secret is not in Kamal secrets, Conductor leaves a localvault
   decryption pointer.** A committed, non-sensitive breadcrumb naming the exact
   vault key and the retrieval command — e.g.:

   ```
   # .kamal/secrets  (git-safe)
   # DATABASE_URL is not stored here. Retrieve via localvault:
   #   localvault get calmpage/DATABASE_URL
   DATABASE_URL=$(localvault get calmpage/DATABASE_URL)
   ```

   The pointer documents *how to get the secret*, never the secret itself.

4. **Self-describing means reproducible by hand.** After Conductor deploys, an
   operator with the repo + authorized SSH key must be able to run
   `bin/kamal console` / `bin/kamal shell` / `psql "$DATABASE_URL"` against the
   real target **without** querying Conductor's UI or database. If a value is
   needed to reach prod and it is neither in the config nor behind a documented
   localvault pointer, that is a violation of this ADR.

## Consequences

- **Positive:** "How do I reach the prod DB?" becomes a one-liner from the repo
  instead of a forensic hunt across DNS, ssh config, and container listings.
  Disaster recovery no longer depends on Conductor being online. Config review
  in PRs reflects reality.
- **Cost:** Conductor's deploy-config generator must be rewritten to write real
  values (per-App, per-environment) and to emit the secrets breadcrumb block.
  Committed configs now change when the target host/service changes — that churn
  is the point (config tracks reality).
- **Secret hygiene unchanged:** raw secrets still never touch git; the only new
  in-repo content is *pointers* (vault key + command), which are safe.
- **Migration:** audit existing Conductor-managed repos for `ENV[...] || <ip>`
  placeholder defaults in `config/deploy.yml`; replace with materialized values
  + localvault pointers. calm.page is the first known offender.
- **Follow-up:** define the canonical localvault key naming
  (`<service>/<SECRET_NAME>`) and whether Conductor writes the pointer block or
  the app template ships it.

## References

- Nodepad capture (PaveLabs): idea `cb458d4e` — original principle.
- Incident evidence: `02-addons/59-calm-page/config/deploy.yml` (placeholder
  defaults), real target `135.181.114.59` / service `calmpage`.
- `74-dev-docs/dev/ADR.md` — ADR format.
