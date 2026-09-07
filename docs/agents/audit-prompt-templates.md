# Audit prompt templates — Conductor extension

**Base class:** `74-dev-docs/agents/audit-prompt-templates.md`. Templates 1–4 there
audit *intent*; Template 5 audits *correctness before shipping*. This file is the
Conductor-specific extension of Template 5 — the file lists that work, the
invariants a generic auditor cannot know to check, and the one question per surface
that cannot be undone.

**When this applies.** A change touching SSH or server access, secrets, the deploy
or rollback path, or a security control. Not ordinary features.

---

## What makes Conductor's audits bespoke

A generic reviewer checks the diff. Conductor's failures have consistently been
**operational invariants a diff cannot show**, so an audit here must be told them:

| Invariant | Where it comes from | What violating it looks like |
|---|---|---|
| Root is a **registration-only** credential | `docs/learnings/root-is-a-registration-only-credential.md` | any repair path that asks for root, or a runbook step a human must run privileged |
| Identity is **assigned, never derived** | ADR 0004 | anything keyed on a name an operator can edit — a container name, a slug, a domain |
| Derived state **declares its refresh** | ADR 0010 | a stored value read as current fact with no age beside it |
| The edge is a property of the **server**, not the deploy method | ADR 0002 / `01-builder` | code that infers kamal-proxy from `deploy_method` |
| One deploy path; Kamal is the **contract**, not the driver | ADR 0003 | a second implementation of an existing operation |
| A creation policy must not govern **deletion** | ADR 0012 | a guard that makes existing resources unmanageable |

**The recurring defect shape**, which is worth stating in the prompt itself: *a step
that is correct in isolation, ordered so that its failure lands after the thing it
would have protected.* Four of the five lockouts found in the SSH work were exactly
that.

---

## The irreversible question, by surface

Ask this **last**, alone, after the finding list is short. It is the one that
decides ship-versus-hand-over, and it changed the outcome twice.

| Surface | Ask |
|---|---|
| SSH / provisioning | *Can any path leave a server where Conductor or the operator cannot log in?* |
| Secrets transport | *Does the value reach a command line, a log, or a world-readable file on any path — including failure paths?* |
| Deploy / rollback | *Can this destroy availability before it validates? Is the incumbent stopped before the new thing is proven producible?* |
| Database naming | *Can a re-provision point an app at a new empty database while its data sits in the old one?* |
| Edge / TLS | *Does this change something global that other zones or apps depend on?* |

---

## File lists that produced useful audits

An unbounded prompt wanders. These scopes worked:

- **SSH identity:** `app/services/server_identity.rb`, `app/services/harden_server.rb`,
  `app/models/ssh_key.rb`, `app/services/ssh_connection.rb`,
  `app/tools/repair_server_identity_tool.rb` + their tests.
- **Secrets transport:** `app/services/deploy_env.rb`, `app/services/app_deployer.rb`,
  `app/services/docker_rollback.rb`, `app/services/kamal_deployer.rb`,
  `app/services/kamal_env_writer.rb`, `app/services/secret_scrubber.rb` + tests.
- **Edge / TLS:** `app/services/caddy_client.rb`,
  `app/controllers/caddy_ask_controller.rb`, `app/tools/enable_on_demand_tls_tool.rb`.
- **Naming / identity:** `app/models/app.rb`, `app/models/database_cluster.rb`,
  `app/services/postgres_cluster_client.rb`, `app/services/dedicated_db_provisioner.rb`.

Always add: *"Do not read `docs/`."* One run without it read 265KB of unrelated
documents and returned no verdict at all.

---

## The five lockout paths, as a standing checklist

Found across nine rounds on one change. Re-ask these of anything touching access:

1. **A file copy that overwrites what it was meant to preserve** —
   `cp /root/.ssh/authorized_keys` over the deploy user's file deletes Conductor's
   own key on a re-run.
2. **Identity established after the credential that could fix it is gone** —
   installing a key *after* `ssh_harden` disables root.
3. **A firewall opened for the wrong port** — the `OpenSSH` ufw profile covers 22
   only; a box listening elsewhere loses every connection including root.
4. **`chmod` after a silently failed `chown`** — narrowing permissions on a file you
   do not own removes the account's existing access.
5. **Verifying before the last mutation** — hardening is a sequence of
   non-transactional steps, so proving access *before* the final sshd reload proves
   nothing about surviving it. **This one is structural**, and is why installing the
   key during provisioning was pulled rather than fixed.

---

## Conductor-specific prompt additions

Append to the base Template 5 prompt:

```
Conductor invariants — treat a violation as a blocking issue even if the code works:
  * root is a REGISTRATION-ONLY credential; a repair path must run as the ordinary
    SSH user and must never produce a privileged command for a human to run
  * identity is assigned, never derived from an editable name
  * a stored value must carry its age; a fact with no refresh is a stale fact
  * the edge is a property of the server, not of deploy_method
  * one deploy path — flag any second implementation of an existing operation

Look specifically for: a step that is correct in isolation but ordered so that its
failure lands AFTER the thing it would have protected.

The suite passing is not evidence here. Every defect found in this area passed a
full green suite, because the author of the fix wrote the tests.
```

---

## Verified-by-execution, not by reading

`74-dev-docs/dev/TESTING_RULES.md` R8 is the rule; in this repo the seam is
`test/support/shell_behaviour.rb` (`in_a_sandbox`, `run_shell`,
`run_shell_with_empty_path`), included in every `ActiveSupport::TestCase`. An audit
finding about a shell command is not resolved until a test **runs** the rendered
command over the awkward inputs.

## Related

- `74-dev-docs/agents/audit-prompt-templates.md` — the base class
- `docs/architecture/rituals.md` — `audit-before-shipping` is the fetchable ritual
- `docs/sessions/2026-09-07-identity-secrets-and-the-shell.md` — the arc this came from
