# `kamal app exec` needs `--reuse` — the bare form runs `:latest` in a new container

**Found:** 2026-08-05 · **Trigger:** a `rails runner` snippet about to be run
against the wrong repo · **Status:** Conductor's code already correct; this is
the rule for hand-run commands

## The rule

```bash
kamal app exec --reuse -r web 'bin/rails runner "..."'   # reads production
kamal app exec -r web 'bin/rails runner "..."'           # reads :latest, in a throwaway
```

Use `--reuse` for anything that inspects or mutates the running application.
Omit it only when you deliberately want a clean container from an image —
a smoke test of a build, or a task that must not touch live state.

## Why

Verified against Kamal 2.12.0 (`lib/kamal/cli/app.rb`, `commands/app/execution.rb`).

Without `--reuse` the `else` branch runs `execute_in_new_container`:

```ruby
docker :run, "--rm", "--name", container_name_for_exec,
       "--network", "kamal", ...env/volumes/options...,
       config.absolute_image, *command
```

The image tag comes from `version_or_latest`, which falls back to
`KAMAL.config.latest_tag` — literally `"latest"`. So the bare form:

- pulls and runs **`<image>:latest`**, which is *not guaranteed* to be the
  release currently serving traffic;
- starts a **new** container (`--rm`, removed on exit) rather than entering the
  live one.

With `--reuse` it resolves `current_running_version` and `docker exec`s into the
container actually serving requests.

## What it does NOT do

It is not a deploy. There is no proxy interaction anywhere in that code path —
no route registration, no traffic swap, no effect on the running container. The
throwaway is genuinely throwaway. The hazard is **reading stale code**, not
breaking the deploy.

Two hazards that are real:

- **Wrong release.** Output looks authoritative but came from `:latest`.
- **Wrong repo.** `app exec` calls `pre_connect_if_required` and reaches real
  hosts. A snippet written for one app, run from a sibling repo, connects to
  that app's production box before failing on a `NameError`. Check the models
  the snippet references belong to the repo you are standing in.

## How Conductor does it

Conductor never emits the bare form:

- `KamalDeployer#kamal_app_exec` (`app/services/kamal_deployer.rb:586`) builds
  `app exec --reuse` — used for gated `db:migrate`, `db:abort_if_pending_migrations`,
  and `db:seed`. Covered by `test/services/kamal_deployer_test.rb:507`.
- `RemoteRailsRunner` (`conductor_app action=runner`) skips Kamal entirely and
  `docker exec`s the resolved running container over SSH, with a `NO_CONTAINER`
  guard — so it works for `docker` apps too, not just Kamal ones.

Prefer the Conductor path (`conductor_app action=runner`) over a hand-run
`kamal app exec`: it targets the live container by construction, it can't pick
the wrong repo, and the call is audited.

## Related

- `docs/dev/adr/0001-self-describing-kamal-deploys.md` — a hand-run
  `bin/kamal app exec` hitting a stale committed host, the other half of the
  "wrong target" failure mode.
- `docs/roadmap/09-app-task-runner.html`, `docs/roadmap/11-web-console.html` —
  both already specify `--reuse`.
