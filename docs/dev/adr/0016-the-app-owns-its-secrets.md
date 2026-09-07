# 0016. The app owns its secrets; Conductor holds only what it must

Date: 2026-09-07

## Status

**Accepted (2026-09-07).** Records the taxonomy that was already half-true in the
code, and rules out a design that was proposed and rejected.

## Context

ADR 0013 left an open problem: a value marked sensitive rides in a command line on
the docker and native deploy paths. Reaching for a fix, the obvious move was to copy
what a well-run CI pipeline does — resolve every secret from a vault at deploy time,
injected process-scoped, never stored.

**That is the wrong shape for a fleet manager, and the operator said so plainly.**

CI is a short-lived job a human triggered, holding a short-lived credential.
Conductor is a long-running operator that must deploy unattended: a webhook at 3am,
a retry after a failed build, a rollback nobody is watching. **Anything requiring a
human to unlock something cannot sit on that path.** Making a vault a runtime
dependency would mean deploys stop when the vault is unreachable — trading a
narrow, understood exposure for an outage.

The second correction matters more: **most application secrets should never reach
Conductor at all.** Rails already solves this. An app keeps its credentials in
`credentials.yml.enc` and Conductor supplies `RAILS_MASTER_KEY` — one secret per
app, not N. Kamal has its own mechanism for the same reason.

The fleet confirms it. The only sensitive values recorded across it are
`RAILS_MASTER_KEY`, `DATABASE_URL`, `SECRET_KEY_BASE` and
`KAMAL_REGISTRY_PASSWORD`; most apps record none. Those are **infrastructure**
credentials. No application's payment key, mail password, or API token is in there,
because each lives in the app's own encrypted credentials.

## Decision

**Three tiers, and Conductor is only responsible for the middle one.**

### 1. Application secrets — the app's own mechanism

Rails credentials by default. Conductor supplies `RAILS_MASTER_KEY` and never sees
what it unlocks. An app with fifty secrets costs Conductor exactly one.

This is the preferred path and should be the advice given at onboarding: *put it in
your credentials, not in Conductor's env.* A value in Conductor's env is a value
Conductor can leak.

### 2. Infrastructure secrets — Conductor must hold these

A bounded set, and bounded on purpose:

| Secret | Why nothing else can hold it |
|---|---|
| `RAILS_MASTER_KEY` | the key that makes tier 1 possible |
| `DATABASE_URL` | Conductor provisions the database, so it alone knows the password |
| registry password | Conductor pushes and pulls the image |
| per-server SSH keys | Conductor's identity on the box |

These are stored encrypted, and the discipline that applies is ADR 0013's: **never
on a command line, never in a log, never in a world-readable file.** Not "never
held" — held is unavoidable — but never *exposed*.

### 3. Conductor's own operational keys

Its master key, encryption keys, MCP token. In its environment, always available,
because a control plane that cannot start without an interactive unlock is not a
control plane.

### localvault's role: seeding and rotation, NOT the deploy path

`localvault` remains how a human seeds and rotates a secret, and how the generated
`.kamal/secrets.<dest>` header documents hand use. It is deliberately **not** a
runtime dependency of a deploy.

## Consequences

**Accepted:**
- Conductor holds infrastructure credentials, and a compromise of Conductor exposes
  them. That is inherent to it being able to deploy unattended, and pretending
  otherwise would be the security theatre this repo keeps finding.
- The docker/native command-line exposure from ADR 0013 is **narrower than it first
  appeared** — it applies to a handful of infrastructure values, not to an app's
  whole secret set. Still worth closing, no longer urgent.

**Rejected:**
- *Resolve every secret from a vault at deploy time.* Correct for CI, wrong here:
  it puts an interactive unlock on an unattended path and makes vault availability a
  deploy dependency. Proposed and rejected the same day.
- *Conductor as the store of record for application secrets.* It invites apps to put
  their whole secret set somewhere that must be able to read it, when Rails already
  offers a store Conductor cannot read.

**Follow-on:** `SECRET_KEY_BASE` appears as a Conductor-held secret for at least one
app and is a candidate for tier 1 — Rails derives it from credentials in the ordinary
case, so holding it separately is a copy with no owner.

Related: ADR 0001 (Conductor generates the kamal artifact), ADR 0013 (one flag, one
guarantee — now correctly scoped by this),
[`docs/architecture/02-secrets/`](../../architecture/02-secrets/README.md) — the
practical map: what is held, how it travels per path, and what none of it buys.
