# 0004. Stable resource IDs and infrastructure revisions

Date: 2026-07-31

## Status

**Accepted (2026-07-31).** Implemented; see status below. Companion to ADR 0003. Where 0003 decides *how* we
deploy, this decides *how deployed things are named and versioned*.

## Context

Every residue bug Conductor has hit has the same shape: **identity derived from
form**.

- A Kamal app's edge route is keyed `<service>-<role>` → `starrrs-web`.
- A native app binds a host port under a name like `starrrs-`.
- A docker app runs as `conductor-<slug>`.

Each name encodes *the form the app was in when the name was created*. When the
form changes — kamal → docker, box A → box B, kamal-proxy → Caddy — the name is
stale but **still live and still serving**. Nothing detects the mismatch, because
nothing can: the only identity is the stale name itself.

That is how a docker deploy left kamal-proxy pointing at a removed container
under the key `starrrs-web` and returned 502 under a green "succeeded"
(`docs/learnings/form-changes-leave-residue.md`). The fix — resolve the live
service key before publishing — is a *workaround for missing identity*. It reads
the stale name back out of the world because we have nothing better to key on.

Names also change for ordinary reasons. An app gets renamed; its slug changes;
its domain moves. Any artifact keyed on a name is orphaned by a rename.

Separately, Conductor has **no concept of infrastructure change**. `Deployment`
records code releases — many per day, all identical in shape. Moving an app from
one box to another, converting a shared database to a dedicated one, or
switching edge is a *different kind of event* entirely, and is currently
invisible: it leaves no version, no history, and nothing to compare against.

## Decision

Two changes, one idea: **identity is assigned, never derived.**

### 1. A stable resource key

Every app gets an immutable resource key derived from its **numeric id**, never
from its name, slug, deploy method, role, or edge:

```text
app-<id>          e.g. app-9
```

This is the key for **every** infrastructure artifact the app owns — edge route
key, container name, service label, systemd unit, volume prefix. It never
changes: not on rename, not on migration, not on a deploy-method switch.

The human-facing name stays free to change, because nothing depends on it.

### 2. An infrastructure revision, versioned separately from code

An app gains `infra_revision`, an integer that increments **only when the app's
form changes** — not on ordinary deploys:

| Event | Code deploy | Infra revision |
|---|---|---|
| Ship a new commit | ✅ new `Deployment` | unchanged |
| Move box A → box B | — | **+1** |
| Switch kamal → docker | — | **+1** |
| Shared DB → dedicated DB | — | **+1** |
| Change edge | — | **+1** |

The composite identity is `<app_id>.<infra_revision>` — app 6 at its first
shape is `6.1`; after a box move, `6.2`. This is **not** a code version, not a
git tag, and unrelated to the commit being deployed. It answers one question:
*how many infrastructure shapes has this app had, and which is it in now?*

### Naming derived from both

```text
edge route key      app-9              # STABLE — cutover replaces the target, never the key
container name      app-9-r3-<sha>     # carries the revision + release
volume prefix       app-9
```

The route key is deliberately stable so a cutover swaps the *target* under a
constant key — which is precisely what prevents two services claiming one
hostname. The container name deliberately carries the revision, because that is
what makes residue **mechanically detectable**.

## Consequences

### What this fixes

- **Residue becomes detectable by pattern.** Any artifact whose revision is not
  the app's current one is, by definition, residue. Today's detection problem —
  "is `starrrs-web` current or stale?" — becomes arithmetic. This is the whole
  point.
- **Renames stop orphaning infrastructure.** Nothing keys on the name.
- **Form changes get a history.** "App 9 is at 6.3; it was docker-on-box-A at
  6.1, kamal-on-box-A at 6.2." Today that history exists only in operators' heads
  and thread files.
- **The live-lookup workaround becomes unnecessary.** `KamalProxyAdapter` reads
  the existing service key back out of the proxy because we have nothing stable
  to key on. With a stable key, it publishes to `app-9` and is done.
- **Infrastructure rollback becomes conceivable** — "revert app 9 to revision 2"
  is a meaningful sentence for the first time.

### Costs and risks

- **The migration is itself a form change**, with exactly the residue risk this
  ADR exists to remove. Existing artifacts are named the old way and are live.
  This cannot be a rename-in-place.
- **Requires an alias period.** Conductor must recognise both the legacy name and
  the stable key while the fleet converges, and record which apps have migrated.
  Reading the legacy key from live state (as `KamalProxyAdapter` now does) is the
  bridge, not the destination.
- **`infra_revision` needs a single choke point.** If form changes can happen
  without incrementing it, the revision lies, and a lying version is worse than
  none. Every path that changes server, deploy method, edge, or DB shape must go
  through one place.
- **Kamal's own naming is not ours to choose.** When Kamal performs a deploy it
  names containers `<service>-<role>-<version>`. Under ADR 0003 Conductor owns
  the deploy path, so it controls container naming — but the Kamal *ops CLI*
  locates containers by `service` label, so the label must remain something Kamal
  accepts. Stable key as the `service` value satisfies both.

## Implementation sketch

1. `App#resource_key` → `"app-#{id}"`. Introduce alongside existing names.
2. `App#infra_revision` (integer, default 1) + `InfraRevision` history rows
   recording what changed, when, and by whom.
3. One choke point — an `App#change_form!` service — through which server,
   deploy method, edge, and DB-shape changes must pass; it bumps the revision and
   writes history.
4. Deploy paths emit `service=<resource_key>` labels and
   `app-<id>-r<rev>-<sha>` container names.
5. Edge publication keys on `resource_key`.
6. A residue check compares live artifacts against the current revision and
   surfaces mismatches in preflight / `situation`.
7. Alias period: resolve legacy names from live state, record migration, drop the
   fallback once the fleet has converged.

## Implementation status

| Piece | Status |
|---|---|
| `App#resource_key` (`app-<id>`) | ✅ used for container labels, edge lookup, log/exec/stop/restart resolution |
| `App#infra_revision` + `InfraRevision` history | ✅ with a baseline revision-1 backfill for existing apps |
| `AppFormChange` choke point | ✅ transfer, DB conversion, UI, and MCP all route through it |
| Guard against bypass | ✅ `App` refuses a form-field change outside it, once the app has ever deployed |
| Durable "ever deployed" | ✅ consults deployment history, not just clearable columns |
| Server edge change → revision | ✅ `EdgeDetector` records one per affected app |
| Container names carry the revision | ✅ `app-<id>-r<rev>-<sha>` on the zero-downtime path |
| Stable key for native units, DB containers, volumes | ❌ still slug-derived |
| Automatic residue detection | ❌ the artifacts are now identifiable; nothing compares them yet |

The remaining two are what turn this from "identity exists" into "residue is
caught automatically". Everything above them is what makes that possible.

## Related

- ADR 0003 — one deploy path; Kamal as artifact contract and ops CLI
- `docs/learnings/form-changes-leave-residue.md` — the incident that motivated this
- `docs/infra/edge-and-deploy-forms.md` — the operational runbook
