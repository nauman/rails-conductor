# 0013. One flag, one guarantee — across every deploy path

Date: 2026-09-05

## Status

**Proposed. An implementation was attempted on 2026-09-05, audited, and reverted
unshipped.** The problem statement and the audit findings below are the value of
this document; the design in "Decision" is not yet safe to build as written. See
"Why the first attempt was reverted".

## Context

Conductor has one "secret" checkbox on an environment variable, and three deploy
paths. The flag means different things on each:

| Path | Where a marked value ends up | Is the flag structural? |
|---|---|---|
| kamal (self-describing) | generated config holds `KEY=$KEY`; value comes from the deploy process env | yes |
| kamal (other) | **`KamalEnvWriter.secrets_content` writes RAW VALUES** to `.kamal/secrets` | no |
| docker | `-e KEY=value` in the `docker run` argv | no — log redaction only |
| native | `export KEY='value'` inside the SSH exec command string | no — log redaction only |

An operator marks a credential secret and gets a redacted deploy log, while the
value sits in argv — readable in the host process table for the life of the
command, and by anything that records commands. The derived `DATABASE_URL`, which
carries the database password, rides there too.

**The flag belongs to the app, not to how the app is currently deployed.** An app
can change deploy method, and must not silently downgrade a credential's transport
when it does — the same class as `flag-residue-when-an-app-changes-form`.

### Two things that are NOT true, and cost time

- **Kamal's `env: secret:` does not give runtime protection.** It keeps the value
  out of a file that could be committed. At runtime the value is in the container's
  environment on every path and `docker inspect` shows it, because anyone reaching
  the Docker daemon is already root-equivalent on that box. Overstating this invites
  someone to store something an env var should never hold.
- **Kamal is not uniformly compliant.** `KamalConfig` emits pointers;
  `KamalEnvWriter` emits raw values. Only the first was examined before the claim
  was made.

## Decision (proposed, not implemented)

**One flag, one minimum guarantee:** a value marked sensitive appears in no
generated configuration, no command line, no deploy log, and no world-readable
file. Residual `docker inspect` / service-account exposure is documented, not
claimed away. The label becomes **"Sensitive"**, with that residue stated in the UI.

## Why the first attempt was reverted

An adversarial audit returned nine blocking findings. Three invalidate the approach
rather than needing a patch:

1. **The transport did not work.** Sensitive values were written to an env file via
   a heredoc — but the heredoc *is* the SSH command string, so the value stayed in
   the remote shell's argv. This is the exact defect the change existed to remove,
   and it was made twice: once on the native path (caught by a test) and again on
   the docker path (not caught, because the test asserted the flag was absent from
   `docker run`, not from the whole SSH command). **scp, or an equivalent that moves
   bytes rather than commands, is the only correct transport here.**
2. **Rewriting the native `EnvironmentFile` is destructive.** Provisioning creates
   `$BASE_DIR/shared/config/.env` as a placeholder for an operator to fill in, and
   the deploy script does `set -a; source "$SHARED/config/.env"; set +a`. Writing
   only Conductor's sensitive keys would delete everything an operator maintains
   there. Any implementation must write the *complete* env, or not own the file.
3. **That file is sourced as shell.** A value containing `$(...)`, backticks, or a
   quote executes or reparses. Conductor writing values into a sourced file turns a
   stored string into remote code execution. The file must move to strict
   `EnvironmentFile` grammar, or be written in a form the script parses without
   evaluating.

The remaining findings, each real and each needing its own answer:

- `docker_rollback.rb` still puts every sensitive value into `docker run -e KEY=value`.
  A guarantee that covers deploy but not rollback is not a guarantee.
- Cleanup was not exception-safe: an exception between write and remove strands a
  0600 file full of live credentials; removal failures were ignored.
- A predictable `/tmp` path is not private. `umask 077` governs creation only —
  redirection follows symlinks and preserves an existing file's mode, so the target
  can be pre-created world-readable.
- Native's first deploy uploads before `app-setup` creates `shared/config`, so it
  fails on a clean host.
- Non-sensitive values live only in the deploy shell, so they do not survive a
  systemd restart; and removing the last sensitive variable leaves a stale file.
- `KamalEnvWriter` writes raw values without enforcing `0600`.

### Two constraints discovered by testing, not reading

- **`docker run --env-file` silently truncates a multiline value to its first
  line** (verified against real Docker). A private key or service-account JSON is
  exactly what gets marked sensitive, so any env-file design must refuse multiline
  values explicitly rather than deliver a fragment.
- **`--env-file` does not hide anything from `docker inspect`.** It removes the
  value from argv and nothing else. It is a partial fix, and worth doing, but not
  the fix.

## Consequences of doing nothing (the current state)

Sensitive values remain in the `docker run` command line and in the native SSH
command string, visible in the host process table during a deploy. On a
single-tenant box every reader of that table is already privileged, which is why
this is a gap to close deliberately rather than an incident. The log redaction in
`secret_scrubber.rb` continues to work and remains necessary but insufficient.

## Rejected

- *Label the flag per path ("protected" / "log redaction only").* Honest about
  today, but it institutionalises the downgrade: the flag is on the app, and
  changing deploy method would silently weaken transport. Disclosure is not a
  substitute for the fix — do both, fix first.

Related: ADR 0001 (Kamal artifacts generated from Conductor's env),
`secret_scrubber.rb`.
