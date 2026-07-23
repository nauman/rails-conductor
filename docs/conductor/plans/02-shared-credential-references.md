# 02 — Shared-credential references: an app env var sourced from the Credentials bucket

Status: **Spec — for review** (2026-07-24). Motivated by the calm.page SES deploy: the
SES SMTP creds live in the org **Credentials bucket** ("used by all apps"), but a deploy
only checks the app's *own* env vars, so the preflight aborted with `Missing required env
var(s): SES_SMTP_USERNAME, SES_SMTP_PASSWORD`. We want to define a shared secret **once**
and let any app reference it — no per-app duplication.

## Goals

1. An app env var can be **sourced from a shared credential** instead of a literal value.
2. The reference is **resolved live at deploy time** — rotating the credential in the
   bucket propagates to every app on its next deploy (single source of truth).
3. The secret is **never duplicated** onto apps and **never logged** (same redaction as
   today's secret env vars).
4. Usable from the **UI** and over **MCP** (`set_env`), so agents can wire an app to a
   shared credential without ever handling the secret value.

## Non-goals

- No new secret store. The Credentials bucket (`Credential` model) stays the source.
- Not a general templating/interpolation system — a var maps to exactly one credential
  field, not an arbitrary expression.
- Copy-on-apply (snapshot into per-app vars) is considered and **rejected** — see
  Alternatives.

## Background: how env + secrets work today

- `EnvVariable` (`app.env_variables`): `key`, encrypted `value`, `secret:boolean`.
  `to_docker_env` / `to_docker_env_redacted` build the container env; secrets are masked
  in anything logged.
- `Credential` (`org.credentials`): `provider`, encrypted `api_key` / `api_secret`, plus
  `account_id`, `region`, `endpoint`. For SES: `api_key` = SMTP username, `api_secret` =
  SMTP password.
- Deploy (`KamalDeployer`): `verify_required_secrets` reads the secret keys listed in the
  repo's `config/deploy.yml` and requires each to exist in **`app.env_variables`**; then
  `KamalEnvWriter` writes `.kamal/secrets` from those vars. The bucket is never consulted
  — this is the gap.

## Design

### A. Data model — a var is *either* a literal *or* a reference

Add two nullable columns to `env_variables`:

| Column | Meaning |
|---|---|
| `credential_id` | FK → `credentials.id`; when set, this var is a reference |
| `credential_field` | which field to read: one of a fixed allowlist |

`value` stays populated only for literal vars; for a reference it is blank (no secret
stored on the app). Allowlisted fields (nothing else is reachable):

```
%w[api_key api_secret account_id region endpoint]
```

### B. Resolution — one method decides literal vs reference

```ruby
class EnvVariable
  CREDENTIAL_FIELDS = %w[api_key api_secret account_id region endpoint].freeze

  def reference?    = credential_id.present?
  def resolved_value
    return value unless reference?
    credential&.public_send(credential_field)   # field is allowlist-validated on save
  end
end
```

Validations: if `credential_id` set → `credential_field` must be in `CREDENTIAL_FIELDS`,
the credential must belong to the **same org** as the app (cross-tenant safety), and
`value` must be blank. A reference is implicitly `secret: true`.

### C. Deploy touch-points — switch `value` → `resolved_value`

Three existing spots, no new machinery:

1. **`KamalDeployer#verify_required_secrets`** — a required key backed by a reference
   counts as present **iff** `resolved_value` is non-blank. If the credential is
   missing/blank/unverified, fail loudly:
   `SES_SMTP_USERNAME references "Amazon SES (InventList)", which is missing or blank.`
2. **`KamalEnvWriter` / `.kamal/secrets`** (and the docker `-e` builder) — write
   `resolved_value`.
3. **Redaction** — `to_docker_env_redacted` and all logging treat a reference as secret
   → `[REDACTED]`. The resolved value never appears in logs or MCP audit rows.

The deployed container is unchanged: it still receives `SES_SMTP_USERNAME=<value>`. Only
the *source* of that value differs.

### D. UI

On an app's Environment Variables form, a source toggle:

```
Key: SES_SMTP_USERNAME
( ) Literal value:          [__________]
(•) From shared credential: [ Amazon SES (InventList) ▾ ]  field [ SMTP username ▾ ]
```

Choosing a credential hides the value box (nothing to type). Field labels map to the
allowlist (`SMTP username → api_key`, `SMTP password → api_secret`, …). The list shows
only the current org's credentials.

### E. MCP — `set_env` gains a reference form

`conductor_app_config action=set_env` accepts, instead of `value`:

```json
{ "action": "set_env", "app_name": "Calm.page", "key": "SES_SMTP_USERNAME",
  "from_credential": "Amazon SES (InventList)", "field": "api_key" }
```

Resolution: `from_credential` matches a credential by name (or id via
`from_credential_id`) within the actor's org; `field` is allowlist-checked. The response
echoes `{ key, source: "credential:Amazon SES (InventList).api_key" }` — never the value.
Composes with the transcript-safety work: a reference carries **no** secret in the call.

## Walkthrough — calm.page + SES

1. Bucket holds one verified `amazon_ses` credential (`api_key`=user, `api_secret`=pass).
2. calm.page: `SES_SMTP_USERNAME → credential.api_key`, `SES_SMTP_PASSWORD → .api_secret`
   (two picks; no secrets typed).
3. Deploy → `verify_required_secrets` sees both resolve → passes → `.kamal/secrets` gets
   the real values → SES sends.
4. Rotate the creds in the bucket → redeploy calm.page (and any other referencing app) →
   new creds flow through. No per-app edits.

## Alternatives considered

- **Copy-on-apply** (a button that snapshots credential fields into each app's env vars):
  simpler, no deploy-path change, but it **drifts** — rotation leaves stale copies until
  each app is re-applied. Rejected for the "used by all apps" case; the live reference is
  a true single source of truth. (Could be added later as a convenience for users who
  explicitly want per-app snapshots.)

## Security

- Fields limited to a fixed allowlist; a reference can't reach arbitrary attributes.
- Cross-tenant: an app may only reference credentials in its own organization.
- Resolved values are secret by construction — masked in logs, deploy output, and the MCP
  audit log (which already redacts `value`-shaped keys).
- Deleting/unverifying a referenced credential surfaces as a **loud preflight failure**,
  never a silent empty env var.

## Edge cases

- Credential deleted while referenced → `resolved_value` nil → preflight blocks with a
  clear message naming the key + credential.
- `field` present on a credential but blank (e.g. `endpoint` unset) → treated as blank →
  same loud failure if that key is required.
- Switching a var literal↔reference is a normal update; the unused side is cleared.
- Non-secret referenced var? Disallowed — references are always secret.

## Test plan (TDD)

- `EnvVariable`: `resolved_value` for literal vs reference; validations (allowlist,
  same-org, blank value); reference is secret.
- `KamalDeployer#verify_required_secrets`: a reference satisfies a required key; a
  missing/blank credential fails with the descriptive message.
- Redaction: `to_docker_env_redacted` masks a reference.
- MCP `set_env`: `from_credential` + `field` creates a reference; response omits the
  value; cross-org credential is rejected.
- Situation/log reads unaffected (no secret leakage).

## Rollout / migration

- Additive migration (two nullable columns); no backfill. Existing literal vars keep
  working unchanged.
- Ship model + resolution + deploy wiring + MCP first (usable headless), UI toggle
  second.

## Open questions (for the reviewer)

1. **Field labelling per provider.** `api_key`/`api_secret` are generic; should the UI
   label them per provider (SES → "SMTP username/password", R2 → "access key id/secret")?
   Proposed: a small per-provider label map; storage stays the generic field name.
2. **Rotation without redeploy.** Live-at-deploy means a rotated credential only lands on
   the next deploy. Do we want an explicit "re-push env" action that rewrites
   `.kamal/secrets` and restarts, without a full rebuild? (Out of scope here; note it.)
3. **`endpoint`/`region` as references.** Useful for S3/R2 config vars, but they're not
   secret. Keep them in the same allowlist (just not masked)? Proposed: yes — same
   mechanism, mask only `api_key`/`api_secret`.
4. **Self-managed apps.** These already resolve some keys from Conductor's own ENV
   (`resolvable_from_conductor_env?`). Precedence when a key is *both* referenced and
   present in ENV? Proposed: an explicit reference wins.

---

### For the reviewer (Codex)

Please scrutinize:
- The **three deploy touch-points** in `KamalDeployer` — is `resolved_value` wired at
  every place a secret value is read/written/redacted? Any path that still reads raw
  `value` would leak or under-provision.
- **Redaction completeness** — confirm a reference can never reach a log/audit sink
  decrypted.
- **Same-org validation** — that a reference cannot point across tenants, incl. via MCP.
- **Failure semantics** — missing/unverified credential must block the deploy, not ship
  an empty env var.
- Whether **live reference** (this spec) vs **copy-on-apply** is the right default for
  the fleet's "one SES cred for all apps" pattern.
