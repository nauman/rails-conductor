# Form changes leave residue — flag the mixed state

**Found:** 2026-07-31 · **Trigger:** production 502 on Starrrs (deployment 215)
· **Status:** deploy-path fix shipped; residue detection still a gap

## The principle

An app has several **forms**, and they change independently:

| Axis | Values |
|---|---|
| Deploy method | `kamal` · `docker` · `native` |
| Edge | `kamal_proxy` · `caddy` · `other` · `none` |
| Home | which server |
| Database | shared cluster · dedicated colocated |

When an app moves from one form to another, **the previous form leaves
residue** — route keys, container names, proxy entries, crontab lines, volumes,
generated config. Residue keeps working right up until something touches it,
which is why nobody notices at migration time. The migration looks clean because
the thing that will break is not exercised until the next deploy.

**A form transition is an event, not an attribute edit.**

## The canonical example

Starrrs was migrated **kamal → docker**. Its kamal-proxy route kept its
kamal-era key `starrrs-web`, because kamal names routes `<service>-<role>` —
not by host. Nothing flagged the app as carrying kamal residue.

Then a docker deploy replaced the container:

```text
deployment 215      succeeded
new container       166a73834701   direct http://127.0.0.1:3000/up → 200
kamal-proxy route   starrrs-web → 15c72f2e2f9e:3000   (container no longer exists)
origin HTTPS        502
```

The deployment reported **succeeded** while the site was down. Two distinct
failures stacked:

1. **`AppDeployer` never repointed the edge.** kamal-proxy routes to a *container
   id*; replacing the container invalidates the route. Caddy routes to a stable
   `host:port`, so it is immune — which is exactly why the docker path got away
   with this on Caddy boxes and only broke on a kamal-proxy box.
2. **The obvious fix would have compounded it.** Publishing the host under a
   host-derived key (`starrrs-com`) leaves *two* services claiming one hostname
   instead of replacing the stale one. The correct move is to resolve the service
   that already serves the host from **live** proxy state and republish under
   that key.

## Why this shape keeps recurring

Kamal was the original default, so ~39 files reference it — including shared
services that docker and native apps also traverse: `deploy_preflight`,
`container_status`, `edge_detector`, `remote_rails_runner`, `app_transfer_plan`,
`decommission_plan`, `stray_proxy_cleaner`. Any of those can quietly assume the
kamal form for an app that has left it.

**Deploy method does not imply edge.** Every combination is real in the fleet.
Assuming otherwise is the bug generator.

## What shipped

`AppDeployer` gained a `republish_edge_route` step, after `health_check` and
before success, which:

- no-ops when the app has no domain, or the server's edge is Caddy;
- resolves the service currently serving the host via `kamal-proxy list` and
  republishes under **that** key, falling back to a derived key only when the
  host has no existing route;
- fails the step rather than reporting success when it cannot repoint.

Regression coverage: `test/services/app_deployer_edge_test.rb`.

## What is still missing — the actual gap

Conductor has **no residue detection**. Nothing notices that an app's current
form disagrees with the artifacts on its box. The fix above stops this one
symptom; it does not stop the next form change from stranding something else.

Proposed, in order:

1. **A residue check in preflight / `situation`**: for each app, compare its
   declared form against live state — proxy entries keyed to another service,
   containers named for a previous method, generated config for a method it no
   longer uses — and surface a red flag.
2. **Make form changes explicit.** Changing `deploy_method` or `edge_type`
   should enumerate what the old form owned and require each item to be migrated
   or explicitly retired, rather than flipping a field.
3. **Never mark a deploy succeeded without verifying the edge target is live.**
   A host-header HTTPS probe against the origin would have caught this at
   deploy time instead of in production.

## The direction this produced

The deeper cause is that **identity was derived from form**: `starrrs-web` encodes
"kamal service + role", so changing form stranded the name. Two ADRs came out of
this incident:

- **ADR 0003** — one deploy path; Kamal retained as an artifact contract and ops
  CLI rather than the deploy driver.
- **ADR 0004** — identity is *assigned, never derived*: a stable `app-<id>`
  resource key plus an `infra_revision` versioning infrastructure shape
  separately from code. Residue then becomes detectable by arithmetic rather
  than by guesswork.

## Related

- `docs/dev/adr/0003-one-deploy-path-kamal-as-contract.md`
- `docs/dev/adr/0004-stable-resource-ids-and-infra-revisions.md`
- `docs/learnings/deploy-lock-stranded-by-self-deploy.md` — the other kamal-form
  failure found the same day
- `docs/dev/adr/0002-caddy-standard-edge.md` — the standing decision to move the
  fleet's edge to Caddy, which would retire this whole failure class
- Thread: `docker-deploy-stale-kamal-proxy-target`
