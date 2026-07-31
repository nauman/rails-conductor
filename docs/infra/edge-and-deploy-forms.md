# Runbook — edges, deploy forms, and form changes

How an app's **deploy method** and its server's **edge** interact, how to
diagnose a 502 after a successful deploy, and what to check when an app changes
form. Assumes SSH access to the box as the deploy user.

## The two independent axes

| Axis | Values | Where it lives |
| --- | --- | --- |
| Deploy method | `kamal` · `docker` · `native` | `App#deploy_method` |
| Edge | `kamal_proxy` · `caddy` · `other` · `none` | `Server#edge_type` (set by `EdgeDetector`) |

**Any combination is valid.** Deploy method does not imply edge — Starrrs is a
`docker` app behind `kamal_proxy`. Assuming otherwise is the single most common
source of bugs in this area.

### What each edge points at — the thing that matters

| Edge | Target | Survives a container replacement? |
| --- | --- | --- |
| `kamal_proxy` | a **container id** (`166a73834701:3000`) | **No** — must be republished |
| `caddy` | a stable **host:port** (`127.0.0.1:9050`) | Yes — nothing to do |

That row is the whole runbook in one line: **a container-targeting edge must be
republished by every deploy path that replaces the container.**

## Symptom: HTTPS 502 immediately after a "succeeded" deploy

Direct-to-container works, the public URL doesn't:

```bash
# On the box — does the app itself serve?
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/up      # 200 = app is fine

# What does the proxy think it should route to?
docker exec kamal-proxy kamal-proxy list
# starrrs-web  starrrs.com  15c72f2e2f9e:3000  running  tls=yes

# Does that container still exist?
docker ps -q -f id=15c72f2e2f9e                                          # empty = stale target
```

App healthy + stale proxy target = this failure.

### Fix

Republish the route to the **live** container, reusing the **existing service
key** (here `starrrs-web`, not a host-derived `starrrs-com`):

```bash
# modifies state — repoints live traffic
docker exec kamal-proxy kamal-proxy deploy starrrs-web \
  --host starrrs.com --target <live-container-id>:<port> --tls

curl -s -o /dev/null -w '%{http_code}\n' https://starrrs.com/up          # expect 200
```

> **Never invent the service key.** A kamal-created route is keyed
> `<service>-<role>`, not by host. Publishing the same host under a different key
> leaves two services claiming one hostname — an intermittent 502 that is much
> harder to diagnose than a constant one. Read the key from `kamal-proxy list`.

Conductor now does this automatically for docker deploys
(`AppDeployer#republish_edge_route`), resolving the key from live proxy state.
The manual procedure above remains the recovery path when the deploy itself
failed before that step.

## Checklist: an app is changing form

Run this **whenever** `deploy_method`, `edge_type`, server, or database shape
changes. The old form leaves residue that works until something touches it.

- [ ] **Proxy routes** — `docker exec kamal-proxy kamal-proxy list`. Any route
      keyed to the old form's service name? Repoint or remove it.
- [ ] **Containers** — `docker ps -a`. Stale containers from the old method
      still holding the app's port? Kamal names them `<service>-<role>-<version>`;
      the docker path uses `App#container_name`.
- [ ] **Generated config** — a `config/deploy*.yml` / `.kamal/secrets` left in a
      repo that no longer deploys via kamal is misleading to the next reader
      (see ADR 0001).
- [ ] **Cron** — managed crontab entries referencing the old container name.
- [ ] **Volumes** — orphaned volumes from a previous database shape.
- [ ] **Edge re-detection** — re-run detection so `Server#edge_type` matches
      reality before the next deploy relies on it.
- [ ] **Deploy once, verify publicly** — not just the container. A host-header
      HTTPS probe is the only check that proves the edge agrees with the app.

## Known gap

Conductor does **not** detect residue. Nothing compares an app's declared form
against what is actually on its box, so a mixed state is invisible until a
deploy trips over it. Tracked in
`docs/learnings/form-changes-leave-residue.md` with a proposed preflight check.

## Related

- `docs/learnings/form-changes-leave-residue.md` — the Starrrs incident and the principle
- `docs/learnings/deploy-lock-stranded-by-self-deploy.md` — the other kamal-form failure
- `docs/dev/adr/0002-caddy-standard-edge.md` — moving the fleet to Caddy retires this class
