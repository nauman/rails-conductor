# 04. The schema gate

> **There is no ADR for this yet, and that is the gap this page exists to close.**
> The gate was built three times, once per deploy path, and the three disagree
> about the one thing that matters: whether it runs *before* traffic moves. This
> page maps what each path actually does. The decision — one gate, before
> cutover — belongs in an ADR once it is agreed.

## The shortest useful version

A Rails release can boot fine against a database that has not been migrated. The
app starts, the health check passes, traffic arrives, and the first request that
touches a new column 500s. Nothing in the deploy noticed, because nothing asked.

The gate is the question nobody asks automatically: **is the schema actually
ahead of, or level with, the code we just shipped?** It is two commands —
`db:migrate` then `db:abort_if_pending_migrations` — and the second is the one
that matters, because it fails loudly when the first silently did nothing.

**Where it runs decides what it is worth.** Run before the release takes traffic,
it is a gate. Run after, it is a post-mortem with a rollback attached.

## What each path does today

| Path | Gate? | Runs where | Traffic already moved? |
|---|---|---|---|
| **docker** (`app_deployer.rb:762`) | yes | a one-off `docker run --rm` container of the **new image**, no published port | **No** — "nothing was stopped, the running release is untouched" |
| **kamal** (`kamal_deployer.rb:973`) | yes | `kamal app exec` against the **live release** | **Yes** — `run_kamal_deploy` (line 112) has already cut over before the gate runs (line 116) |
| **native** (`native_deployer.rb`) | **no** | — | — |

The docker path is the one that got it right. It runs the migration in a
throwaway container built from the same image reference the release will use, on
the same network, with the same env — so the schema is verified against the code
that will serve it — and it publishes no port, so it cannot collide with the
incumbent. If it fails, nothing has been stopped.

The kamal path runs the same two commands in the wrong place. `kamal deploy` is a
single command that builds, boots, health-checks **and switches traffic**; the
gate fires afterwards. `DeployPreflight` already says so in prose, to its credit:

> post-deploy gate present (db:migrate + abort_if_pending, fail-loud). **Runs
> AFTER the release swaps** — not a pre-deploy drift check.

So on eight of the fleet's apps, the gate's verdict arrives after production is
already serving the release it was meant to vet.

## Why the docker shape is the right one

It needs no cooperation from Kamal's roll. The obstacle to gating a kamal deploy
is that `kamal deploy` ends in cutover and offers no "boot but hold traffic" for
the ordinary path. A one-off container sidesteps that entirely: it is a container
of the new image, run and discarded, *before* `kamal deploy` is invoked at all.

The same reasoning retires the auto-rollback question. Rolling code back after a
**partial** migration leaves old code against a new schema — the inverse failure,
usually worse, and adjacent to
[the multi-database rollback learning](../../learnings/db-rollback-aborts-silently-on-multi-database.md).
Gate before cutover and the question mostly dissolves: traffic never moved, so
the correct response to a failure is to **stop**, not to roll anything back.

> A deploy that refuses to proceed needs no rollback. That is the whole argument
> for moving the gate rather than adding recovery around it.

## What the gate does not catch

**A gate is not a drift check.** It runs during a deploy. A database that drifts
between deploys — a migration applied by hand, a restore from an older dump — is
invisible until the next one. Nothing currently asks that question on a schedule.

**A silent entrypoint is upstream of all of this.** Rails' older
`bin/docker-entrypoint` runs `db:prepare` only when the command is positionally
`./bin/rails server`:

```sh
if [ "${1}" == "./bin/rails" ] && [ "${2}" == "server" ]; then
```

Under Kamal — or anything fronting Puma with thruster — the command does not
match, so `db:prepare` never runs and the omission is silent. Upstream fixed this
in [rails/rails#58740](https://github.com/rails/rails/pull/58740). An app whose
repo still carries the positional form is one deploy away from the exact failure
this gate exists to catch, and the gate covers for it rather than fixing it.

Detecting that is worth doing at readiness time, with one rule from
[a detector's remedy is a production action](../../learnings/a-findings-remedy-is-a-production-action.md):
if the entrypoint cannot be read, the finding must say **"could not check"**, never
"not affected". No comparison, no accusation.

## Coverage, per app

The gate follows the **driver**, not the artifact — an app Conductor does not
deploy gets no gate, whatever it is built with.

| App | Path | Gated today | After the move |
|---|---|---|---|
| Kuickr, Calm.page, agpages, minimalnarrow, platepose, Wiseherds, railslink, Conductor | kamal | yes, **after cutover** | before cutover |
| Starrrs, Kuickbox | docker | yes, before cutover | unchanged |
| InventList | external driver (`bin/deploy-ssdnode`) | **no** | needs the check in that script |
| intellectaco | native (Hatchbox) | no | out of scope — no container, no entrypoint |

InventList is the worst case and for a second reason: its deploy script cannot
report to Conductor at all (`conductor.deploy_webhook_secret` is unset), so
Conductor can neither gate it nor observe the result. Fixing the gate there means
fixing the reporting first.

`app.migrates` turns the gate off per app, and the docker path is explicit that
this is a real choice with a real consequence — the log says a release "can go
live against an out-of-date schema and 500 in production" and keeps saying it.

## What is proposed

1. **Move the kamal gate before cutover**, using the docker path's shape: a
   one-off container of the new image, run before `kamal deploy`.
2. **Detect the positional entrypoint** at readiness and on deploy, citing
   rails/rails#58740 so the app gets fixed at source rather than covered for.
3. **Name it once as a ritual** so runbooks cite a shared schema gate instead of
   each carrying a hand-written step ([ADR 0007](../../dev/adr/0007-findings-cite-rituals.md)
   already has findings cite rituals).

Auto-rollback is deliberately **not** proposed for v1. Once the gate is
pre-cutover there is nothing to roll back from, and the failure mode it would
introduce is worse than the one it removes.
