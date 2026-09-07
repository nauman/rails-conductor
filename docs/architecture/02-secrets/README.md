# 02. Secrets

> **The decisions are [ADR 0016](../../dev/adr/0016-the-app-owns-its-secrets.md)**
> (who holds what) **and [ADR 0013](../../dev/adr/0013-one-flag-one-guarantee.md)**
> (how it travels). This page is the practical map: what Conductor actually holds,
> how it reaches a container on each path, and which of those paths still exposes it.

## The shortest useful version

**Most of an app's secrets should never reach Conductor.** Put them in the app's own
`credentials.yml.enc`; Conductor supplies `RAILS_MASTER_KEY` and never sees what it
unlocks. Fifty secrets cost Conductor one key.

What remains is a small **infrastructure** set that nothing else can hold, and the
rule for it is not "never held" — held is unavoidable for something that deploys
unattended — but **never exposed**: not on a command line, not in a log, not in a
world-readable file.

## Three tiers

| Tier | Lives where | Conductor sees it? |
|---|---|---|
| **Application** — payment keys, mail passwords, API tokens | the app's `credentials.yml.enc`, in its own repo | **No** |
| **Infrastructure** — `RAILS_MASTER_KEY`, a provisioned `DATABASE_URL`, registry password, per-server SSH keys | Conductor, encrypted columns | Yes, necessarily |
| **Conductor's own** — its master key, encryption keys, MCP token | Conductor's environment | Yes, always |

The middle tier is bounded on purpose. Across the fleet the only sensitive values
recorded are the master key, a derived `DATABASE_URL`, `SECRET_KEY_BASE` and a
registry password — and most apps record none at all.

> `SECRET_KEY_BASE` is a live oddity: Rails normally derives it from credentials, so
> holding it separately is a copy with no owner — the pattern that causes most of the
> drift bugs in this repo.

## How a value reaches a container, per path

This is the table that did not exist anywhere, and it is why the exposure was
misjudged for a while.

| Path | Ordinary values | Sensitive values | Exposed to |
|---|---|---|---|
| **kamal** (self-describing — all kamal apps) | generated `deploy.<dest>.yml` | `.kamal/secrets.<dest>` holds `KEY=$KEY` **pointers**; values resolve from the deploy process env | container env |
| **docker** | `-e KEY=value` on the run command | a `0600` file uploaded over **scp** into an exclusively-created `0700` directory, referenced by `--env-file`, removed on every exit path | container env |
| **native** | `export KEY='value'` in the SSH command | **the same — still in the command string** | container env, **and the remote process table while the command runs** |

**Native is the open gap.** Every value, sensitive or not, is exported inside the
command handed to `sh -c`, so it is visible in the host's process table for the life
of that command. Two attempts to close it were reverted, for reasons that still hold:
the file the deploy script would write is `source`d as shell — so writing values into
it turns a stored string into remote execution — and it is operator-maintained, so
Conductor rewriting it destroys configuration it does not own.

## What none of this buys

**A value in a container's environment is visible to `docker inspect`.** That is
inherent to environment variables: anyone who can reach the Docker daemon is already
root-equivalent on that box. Protection from *that* needs mounted secret files,
systemd credentials, or runtime retrieval — not a flag.

So the flag's honest promise is: *kept out of generated config, command lines, and
deploy logs.* It is labelled **"Sensitive"** rather than "Secret" for that reason. An
earlier version promised more than an environment variable can deliver, which invites
someone to store something that should never be one.

## Two constraints found by testing, not reading

- **`docker run --env-file` silently truncates a multiline value to its first line.**
  A private key or service-account JSON — exactly what gets marked sensitive —
  arrives as `-----BEGIN-----` and fails later, far from the deploy. `DeployEnv`
  refuses such a value rather than delivering a fragment.
- **scp does not make a predictable path safe.** Its receiver opens an existing
  destination without `O_EXCL` or `O_NOFOLLOW`, so a planted symlink keeps its own
  permissions and `mode: 0600` guarantees nothing. The upload directory is created
  with `mkdir` *without* `-p`, which refuses a path that already exists.

## localvault: seeding and rotation, not the deploy path

`localvault` is how a human seeds and rotates a secret, and what the generated
`.kamal/secrets.<dest>` header documents for hand use (`kamal console` from a
laptop). It is **deliberately not** a runtime dependency of a deploy.

Resolving every secret from a vault at deploy time is the right shape for CI — a
short-lived job a human triggered — and the wrong shape here. Conductor deploys
unattended: a webhook at 3am, a retry after a failed build, a rollback nobody is
watching. An interactive unlock cannot sit on that path, and making vault
availability a deploy dependency trades a narrow, understood exposure for an outage.

## Redaction is not protection

Worth stating because the codebase got this wrong twice:

- The repository deploy key was base64'd into the SSH command with the **logged**
  copy redacted. Base64 is reversible, so the key sat in the remote process's argv —
  the redaction hid it from us, not from the host. It now travels by scp.
- `DockerRollback` carried a second copy of the env-rendering logic with **no**
  redaction at all, so a rollback wrote every credential into the deployment record
  in clear while the deploy path had been redacting for months. One object now serves
  both.

`SecretScrubber` still matters — it redacts on two grounds, keys Conductor records as
secret and keys that merely *look* secret — but it is the last line, not the control.

## Related

- [ADR 0016](../../dev/adr/0016-the-app-owns-its-secrets.md) — who holds what
- [ADR 0013](../../dev/adr/0013-one-flag-one-guarantee.md) — one flag, one guarantee
- [ADR 0001](../../dev/adr/0001-self-describing-kamal-deploys.md) — generated artifacts
- `app/services/deploy_env.rb`, `app/services/kamal_config.rb`, `app/services/secret_scrubber.rb`
