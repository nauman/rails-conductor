# 0011. A database is named by convention and reached by assigned identity

Date: 2026-09-05

## Status

**Accepted (2026-09-05).** Implemented behind a migration gate; existing shared clusters keep their typed name until an alias is deliberately attached. Raised by the operator while reviewing
how a new app gets Postgres: *"I would not make this cluster name based on
container name — during transfers and other things it is a very itchy case of
variables depending on fragile things."*

## Context

Every app's connection string is built here:

```ruby
# Database#database_url
"postgres://#{username}:#{password}@#{database_cluster.container_name}:#{port}/#{name}"
```

`container_name` is a **mutable display column** on `database_clusters`, typed in
by an operator at `register_cluster` and editable afterwards. It is doing two
unrelated jobs at once: naming the row for a human, and being the **DNS name Docker
resolves** for every dependent app.

The damage is bounded by one accident of design — the URL is re-derived at each
deploy rather than baked into an image — so a rename breaks the *next* deploy, not
the running app. That bound is real, and it is also why the failure would be
confusing: nothing breaks at the moment of the change, and the deploy that fails is
the one after, for a reason no longer in anyone's recent memory.

**Transfers are the sharp case, and they are what raised this.** Source and target
are different cluster records on different hosts. The transfer runner replicates
`source_url → target_db.database_url` and then relies on `DATABASE_URL` resolving
to the target. Both ends of that are derived from names a human typed and can
retype, on the one operation where the app's data is in flight between two boxes.

This is the same root as four bugs already fixed this month — a backup dumping from
a container name the app had outgrown, decommission filtering on guessed names, ops
asking `deploy_method` a driver question, a zone list cached under an assumption.
**ADR 0004 assigned identity to end exactly this, and the database layer never
adopted it.**

## Decision

**A cluster gets an assigned identity, and apps reach it by a stable network alias
carrying that identity.**

1. **Assigned key.** A cluster has `cluster-<id>`, in the spirit of ADR 0004's
   `app-<id>`. It is never derived from a name, a slug, or anything an operator
   edits.
2. **The alias is the hostname.** When Conductor creates a cluster container it
   attaches `--network-alias cluster-<id>`; when it *registers* an existing one, it
   attaches the alias to the running container. `Database#database_url` uses the
   alias, so Docker DNS resolves it regardless of what the container is called.
3. **`container_name` becomes a display name and a bootstrap hint** — used to find
   the container the first time, never to reach it afterwards. Renaming it becomes
   what an operator expects: cosmetic.

An alias rather than a label because a connection string needs a name Docker DNS
can resolve; a label is not addressable from inside a container. This is the same
"assigned, not derived" principle as ADR 0004, expressed in the one namespace that
has to answer at runtime.

## Consequences

**Accepted:**
- Cluster registration gains a step: attach the alias, and verify it resolves
  before anything depends on it.
- Existing apps keep working on the old host until their next deploy re-derives the
  URL. The change is therefore gradual and needs no coordinated cutover — but
  "gradual" means a period where two apps on one cluster reach it by different
  names, and that has to be expected rather than diagnosed.
- A transfer plan can name the target by assigned identity, so the plan stays valid
  even if someone renames a cluster between plan and execute.

**Costs:**
- Attaching an alias to an already-running container means
  `docker network disconnect` + `connect --alias`, which briefly interrupts that
  container's connectivity on that network. For a database container that is a real
  interruption, not a cosmetic one, and it must be done deliberately rather than as
  a side effect of a read. This is the main reason this is an ADR and not a patch.
- Two names for one thing during migration, until every app has redeployed.

**Rejected:**
- *Validate `container_name` against the live container instead.* Detects the
  breakage rather than preventing it, and only at deploy time, which is the same
  half-fix pattern ADR 0010 exists to name.
- *Store a resolved IP.* Container IPs change on restart; strictly worse.
- *Leave it, since the URL is re-derived each deploy.* That bounds the blast radius
  and does not remove it, and it is precisely the transfer path — the one carrying
  live data — that gets no benefit from the bound.

## Amendment (2026-09-05): only the SHARED case was broken

Implementing this found the decision was drawn too wide, twice, and the existing
tests caught both.

**Dedicated clusters were already right.** Their `container_name` is
`app-<id>-db`, assigned by `App#dedicated_db_container_name` — stable by
construction and needing no alias. The first implementation re-hosted them anyway,
which would have changed the connection string of every existing dedicated database
for no gain.

**And the check for "is this name assigned?" was itself a guess.** It pattern-matched
`/app-\d+-db/`, which missed the legacy `<slug>-db` spelling and would have aliased
a cluster that was already stable. Guessing whether a name is trustworthy *from its
shape* is the same fragility this ADR removes.
`App#dedicated_db_container_candidates` already answers it authoritatively — it lists
both spellings precisely so callers need not know which era created a container.

So the scope is exactly: **a cluster whose name a human typed** — the shared,
operator-registered case.

## Naming, which is the same decision from the other end

Two provisioning paths disagreed. The UI derived `<app>_production` / `<app>` from
the app; the MCP tool required a caller-supplied name with no default. **The path
most likely to provision a brand-new app — an agent — was the one with no
convention at all.** A convention only one caller follows is a preference.

`App#database_name` and `#database_username` are now the single source, and both
paths use them. The MCP tool defaults to them when given an `app_id` and keeps an
explicit name only for adopting a database that already exists.

The derivation must produce a legal identifier **by construction**, because these
names reach `CREATE DATABASE` and `CREATE ROLE` as interpolated SQL: everything
outside `[a-z0-9_]` collapses to `_`, and a leading digit is prefixed, since
postgres will not accept one unquoted.

## Status detail

| Step | State |
|---|---|
| Decision recorded | Done — this ADR |
| One naming convention, used by UI and MCP | **Done** — `App#database_name` / `#database_username` |
| `cluster-<id>` assigned key | **Done** — `DatabaseCluster#resource_key` |
| Dedicated clusters left alone (already assigned) | **Done** — `#assigned_container_name?` asks the app |
| `database_url` uses the alias for shared clusters | **Done**, gated on `network_alias_attached_at` |
| Attaching the alias to an existing container | Not built — needs a deliberate operator action; reconnecting a live DB container's network is a real interruption |
| Alias attached automatically at cluster creation | Not built |
| Transfer plan names the target by assigned identity | Not built |

Related: ADR 0004 (identity is assigned, never derived — the principle this
applies), ADR 0010 (derived state declares its refresh),
`docs/architecture/derived-state.md`.
