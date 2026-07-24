# 04 — App transfer between boxes + dedicated database containers

Status: **Spec — DRAFT for annotation** (2026-07-24). Iterating interactively — each
`⟶ ANNOTATE` marks a decision that needs the operator's call. Motivated by the
calm.page situation: moving a running app to another box, where the two boxes can
run **different edges** (kamal-proxy vs Caddy). Builds on the prior discussion in
the thread; product truth once settled.

## Why this is worth doing

"Move a workload between boxes" is the essence of fleet management. Today it's a
manual, error-prone forensic exercise. The blocker isn't missing primitives —
Conductor already has deploy-to-server, `DatabasePull` (pg_dump→scp→restore),
`CaddyClient`, `CloudflareClient` (DNS), per-server `edge_type`. The blocker is
(a) **orchestration** and (b) **state coupling** — the database is welded to the
box. This spec fixes both.

## Part 1 — The core architectural bet: dedicated, runtime-wired database containers

**Proposal (operator's instinct):** each app gets its **own Postgres container**
with its own volume, and the app's DB config is **injected at runtime** (Hatchbox
does this: it writes `database.yml` at boot; the DB is a separate container). The
image carries **no** DB coordinates — they're injected — so the *same image* runs
against whatever DB endpoint it's pointed at.

Why this makes migration easy: the app's state becomes a **self-contained unit**
(`<app>-db` container + volume). Moving an app = move/replicate that one unit and
re-inject the endpoint — no untangling one app's data out of a shared cluster.

### Where this diverges from today

Conductor's current "fleet" topology uses a **shared Postgres cluster** (one
container, a database+role per app) for density. Dedicated-container is the
opposite end of the axis: portability + isolation over density.

⟶ **ANNOTATE (Decision A — the big one):** shared-cluster vs dedicated-container as
the model. Proposed: **make it a per-app choice** — `database_mode: shared |
dedicated` — defaulting to `dedicated` for new apps (portable by default), with
`shared` available for dense/low-value apps. Both coexist. Agree, or should
dedicated be the *only* model going forward?

### Trade-offs (honest)

| | Dedicated container per app | Shared cluster (today) |
|---|---|---|
| **Migration** | Self-contained unit — move the container+volume | Must pg_dump one DB out of a shared cluster |
| **Isolation** | Per-app crash/load/tuning/PG-version | One app can starve others; one PG version |
| **Backup/upgrade** | Per-app, independent blast radius | All-or-nothing per cluster |
| **Resource cost** | N Postgres baselines (RAM/conns) — adds up on a dense box | One baseline for many apps |
| **Ops surface** | N containers to patch/monitor | One cluster |
| **Connection wiring** | Each needs a network endpoint | One endpoint |

⟶ **ANNOTATE (Decision B):** the runtime-injection mechanism. Options: (i) write
`config/database.yml` into the container at boot; (ii) inject `DATABASE_URL` env at
deploy; (iii) both. Proposed: **DATABASE_URL env injected at deploy**, since Kamal
+ 12-factor already center on it and it composes with the shared-credential-
reference work (plan 02). `database.yml` file injection only if an app needs it.

### What dedicated containers require Conductor to own

- Provision `<app>-db` (Postgres container + named volume + network) on a server.
- Generate the DB + role + password, expose the endpoint (Docker network name).
- Inject the endpoint into the app at deploy (never bake it into the image).
- Back it up (per-app) and health-check it as its own unit.

## Part 2 — The edge is pluggable (kamal-proxy vs Caddy)

Conductor already stores `Server#edge_type` (`caddy` / `kamal_proxy` / `other` /
`none`). A transfer doesn't need the two boxes to match — it needs Conductor to
render the destination edge's config. Introduce an **edge adapter**:

```
Edge.for(server).publish(domain:, upstream:)   # dispatch by server.edge_type
  → CaddyAdapter        # Admin API upsert (exists today as CaddyClient)
  → KamalProxyAdapter   # deploy.yml / proxy config (the missing half)
```

Today `add_domain` assumes Caddy. The missing piece is the kamal-proxy adapter.
Once both exist, "publish this app's domain on box B" is uniform regardless of B's
edge — cross-edge transfer stops being special-cased. (Converges with ADR 0002's
Caddy-standard direction, but doesn't wait on it.)

⟶ **ANNOTATE (Decision C):** build the KamalProxyAdapter, or declare Caddy the
required edge for any transfer target (simpler, but forces Caddy on the fleet)?

## Part 3 — The transfer workflow

An app is tied to a box across orthogonal axes; a transfer reconciles each, staged
for minimal downtime:

1. **Plan / dry-run** — Conductor emits exactly what will change: compute
   (redeploy to B), edge (A's config → B's edge translation), database (mode +
   migration method), DNS (repoint). No mutation. This is the "make sense of it"
   artifact.
2. **Stand up on B (parallel)** — deploy the app to B (Kamal builds on B over
   SSH); provision `<app>-db` on B if dedicated.
3. **Replicate state** — dedicated: base-backup/restore or logical replication
   into B's DB container; shared: `DatabasePull` A→B. Keep A live meanwhile.
4. **Cut over** — publish the domain on B's edge, repoint DNS (CloudflareClient
   for CF domains), let B's edge mint TLS. Final DB sync + switch DATABASE_URL.
5. **Verify** — health + `site_check` through B; confirm shipped commit_sha.
6. **Drain + decommission A** — stop A's container/route after a hold window;
   keep A's DB as a rollback snapshot for N days.
7. **Rollback** — at any step before decommission, DNS/edge point back to A.

⟶ **ANNOTATE (Decision D):** downtime target. Cold (dump/restore, minutes of
write-downtime) is simple; near-zero (logical replication) is more moving parts.
Proposed: **ship cold-cutover first** (with a maintenance window), add logical
replication as a follow-up. Acceptable?

## Open questions (for annotation)

1. Same-box multi-tenancy for dedicated DBs — port/socket allocation strategy?
2. Backups: does per-app dedicated DB reuse the existing S3/R2 backup path, one
   schedule per DB container?
3. PG major-version differences between A and B — block, or dump/restore across
   versions (client-version rules like `DatabasePull` already handles)?
4. Does "transfer" also cover **duplicate** (clone app to B, keep A) — same
   machinery, skip decommission?

## Test plan (sketch — fill once decisions land)

- Edge adapter: publish/unpublish on a Caddy server and a kamal-proxy server.
- Dedicated DB provision + runtime DATABASE_URL injection (never baked in image).
- Transfer dry-run emits the correct change set; cold cutover moves data + routes
  + DNS; rollback restores A.

---

### For the reviewer / annotator

Mark up each `⟶ ANNOTATE` decision inline. The two that gate everything else:
**Decision A** (dedicated-container as default DB model) and **Decision C**
(build the kamal-proxy edge adapter vs require Caddy). Everything else is
sequencing.
