# 0014. A build venue is chosen, not inherited

Date: 2026-09-06

## Status

**Accepted (2026-09-06).** Implemented for new apps; apps that predate the choice
keep their current behaviour until moved deliberately.

## Context

Conductor had a class that ranked build venues and a separate line of code that
decided them, and they had nothing to do with each other.

`BuildPlacement` orders three venues — CI (free, nowhere near production), a server
opted in with `build_role`, and the control machine — with a comment explaining that
the ladder exists to stop production boxes being the default. It is consulted by
**`DeployPreflight` only**. It advises. It has never routed a build.

The actual decision is one line in `KamalDeployer#deploy_env`:

```ruby
env["DOCKER_HOST"] = "ssh://#{deploy_server.ssh_user_or_default}@#{deploy_server.ip_address}"
```

guarded by `if @ssh_home`, which is set when `write_ssh_key` produced a file, which
happens when the target server has a stored SSH key. **So where an app builds
followed from whether somebody had stored a key for its server** — a fact about
credential bookkeeping, standing in for a decision about capacity and blast radius.

The fleet shows it: recorded `build_host` values are a mix of `control-machine` and
`ssh://deploy@<target>`, across apps on the same box, with nobody having chosen
either. Two apps build on machines that serve production traffic.

The existing test for this was named *"builds over SSH (DOCKER_HOST), no
docker.sock…"* — documenting the accident as though it were the design.

## Decision

**An app carries a `build_venue`, and that value decides where the image is built.**

- **`control`** — do not hand the build to a remote daemon. Conductor builds where
  Conductor runs. Bigger machine, and a failed build cannot touch the box serving
  the app.
- **`target`** — the app's own server. What most apps do today; needs a reachable
  host with a key; makes the build compete with the traffic that host serves.
- **`NULL`** — the app predates the choice, and keeps its current behaviour.

New apps choose `control`.

**A venue that cannot take the build fails the deploy and names why.** There is no
runtime substitution. This is the operator's explicit requirement and it is right:
substituting makes the choice decorative, and relocating a build is exactly how an
app ends up compiling on the machine it serves from — the outcome the venue ladder
was written to prevent and never did.

The check runs **before any clone**, so a policy problem is not buried under
whatever else failed first.

## Consequences

**Accepted:**
- Two mechanisms now describe venues: `BuildPlacement` (which advises, and still
  answers "what are my options and what does each cost") and `build_venue` (which
  decides). That duplication is a debt to settle — `BuildPlacement` should become
  the thing that *proposes* a venue at setup, not a parallel ranking consulted at
  deploy time.
- Apps with `NULL` still build wherever the key configuration happens to send them.
  They are not fixed by this ADR; they are merely no longer doing so invisibly.
- Choosing `target` is still legitimate and sometimes right — a warm cache on the
  box, no image pull across the network. It is now a decision with a stated cost.

**Rejected:**
- *Let the ladder route at deploy time, substituting when a venue is unavailable.*
  Rejected by the operator and correctly: a venue that changes under you is not a
  policy, and the substitution most likely to happen — falling back to the machine
  serving traffic — is the one you least want unattended.
- *Require a registered self-managed app to identify the control machine.* This was
  built, and 42 test failures showed it refuses deploys for every fleet that has not
  registered Conductor as one of its own apps — i.e. every fresh install. `control`
  cannot fail: it means "build here", and Conductor is here. Naming the box is
  reporting, not permission.
- *Flip every existing app to `control` now.* It is the better venue, and doing it
  in one migration would change where nine live apps build, discovered whenever each
  next deploys.

## Not built

- **A CPU ceiling and a build lock on the control machine.** With builds moving
  there, two concurrent builds or one large one compete with the apps that box
  serves. `nice` is not sufficient — it constrains the Kamal client while the work
  happens in daemon-managed BuildKit containers, and CPU shares are relative rather
  than a ceiling. The real controls are a `--driver-opt cpu-quota` on the buildx
  worker and a host-wide `flock` held through push.
- **`BuildPlacement` proposing the venue at setup** rather than ranking at preflight.

Related: ADR 0001 (Conductor generates the kamal artifact), ADR 0003 (one deploy
path), `docs/architecture/builder.md`.
