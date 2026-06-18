# Learning — Build-over-SSH host-key verification (Conductor as Kamal control machine)

> Captured while making the through-Conductor Kamal deploy work end-to-end. When
> Conductor's container is the Kamal control machine, it builds the image on the
> **target's** docker daemon over SSH (`DOCKER_HOST=ssh://deploy@<ip>`) so no
> docker.sock has to be mounted. That SSH hop has a sharp edge.

## Symptom

A first-ever through-Conductor deploy dies in the build step:

```
docker buildx create --name kamal-local-docker-container --driver=docker-container
ERROR Couldn't create remote builder: Host key verification failed.
...
ERROR: no builder "kamal-local-docker-container" found
```

`docker buildx`'s connection to the remote daemon (and Kamal's own net-ssh) verify
the target host key. On first contact there's no entry in `known_hosts`, and the
connection does **not** honor `StrictHostKeyChecking=accept-new`, so it fails hard.

## The trap (why the "obvious" fix didn't work)

The first fix seeded the host key with `ssh-keyscan` into an **isolated `$HOME`**
(`/rails/tmp/kamal/.sshhome_<app>/.ssh/known_hosts`) and set `HOME=` that dir.
It still failed. A `ssh -vvv` probe showed why:

```
debug3: expanded UserKnownHostsFile '~/.ssh/known_hosts' -> '/home/rails/.ssh/known_hosts'
```

**OpenSSH resolves `~` from the passwd database (getpwuid), not the `$HOME` env
var.** So every ssh the build spawns reads `/home/rails/.ssh/...`, ignoring the
isolated home entirely — the seeded key and custom `~/.ssh/config` were never
seen. (Proof: passing `-o UserKnownHostsFile=<our file>` explicitly made host-key
verification pass — it only then failed on auth, because the identity was in the
ignored home too.)

## The fix

Write into the **real `~/.ssh`** (`Dir.home`) that ssh actually reads — not a
fake `$HOME`:

- per-app identity key `~/.ssh/conductor_<slug>`,
- an idempotent marked `Host <ip>` stanza in `~/.ssh/config`
  (`IdentityFile`, `IdentitiesOnly yes`, `StrictHostKeyChecking accept-new`,
  `UserKnownHostsFile ~/.ssh/known_hosts`),
- the pre-trusted host key seeded into `~/.ssh/known_hosts` (skip if already
  trusted via `ssh-keygen -F`).

Do **not** set `HOME` for the kamal subprocess — ssh ignores it anyway. Keep
`DOCKER_HOST=ssh://…` so the build runs on the target daemon. In tests, override
the home with `CONDUCTOR_SSH_HOME` so they never touch the real `~/.ssh`.

Implemented in `app/services/kamal_deployer.rb` (`setup_ssh_home` /
`write_ssh_config_block` / `seed_known_hosts`).

## Takeaways

- **`~` ≠ `$HOME` for OpenSSH.** Anything that shells out to `ssh` (git, docker's
  ssh connhelper, Kamal net-ssh) reads the passwd-database home. Faking `$HOME`
  does not redirect it.
- **`accept-new` isn't honored by every ssh consumer** on first contact — pre-seed
  `known_hosts` rather than relying on it.
- **Instrument the live path.** A non-fatal pre-flight that runs the exact
  connection (`ssh … echo ok` + `docker version` over the same `DOCKER_HOST`)
  localized the failure to the handshake in one deploy instead of guessing.
