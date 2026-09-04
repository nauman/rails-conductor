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
explicit name only for creating one under a different name. It does **not** adopt an
existing database — provisioning issues `CREATE ROLE` and `CREATE DATABASE` and
fails if either exists — and an earlier draft of this ADR claimed otherwise.

The derivation must produce a legal identifier **by construction**, because these
names reach `CREATE DATABASE` and `CREATE ROLE` as interpolated SQL: everything
outside `[a-z0-9_]` collapses to `_`, and a leading digit is prefixed, since
postgres will not accept one unquoted.

## Amendment (2026-09-05): the derivation is spent once a database exists

An adversarial audit of the first implementation returned six findings, and they
divide into two groups that are really one idea.

**A derived name has to be legal, unique, and stable — the first pass secured
none of the three.** Postgres truncates identifiers at 63 bytes, so a long slug
silently lost its `_production` suffix and two apps could land on a name neither
chose. `foo-bar`, `foo_bar` and `foo.bar` all collapse to `foo_bar`, so the second
app's `CREATE ROLE` failed and left an `error` row. And a slug like `select` or
`postgres` passed a character-class check before colliding with a keyword or an
existing administrative role.

The answer is not to derive harder. **When a name cannot be trusted to be legal or
unique, stop deriving and use the identity that was assigned** — `app_<id>`, the
same move ADR 0004 makes everywhere else. Truncation carries the id for the same
reason. Where two apps do collide, the *older* keeps the plain name: its database
already exists, so the newcomer is the one that must give way.

**And a derivation must not outlive the fact it produced.** Re-deriving after a
slug edit would aim a re-provision at a new, empty database while the app's data
stayed in the old one — silently, because nothing compares the two. So
`database_name` and `database_username` now return the **recorded** name whenever a
`Database` row exists, and derive only when provisioning something that does not
yet exist. This is ADR 0010 applied to naming: prefer the stored fact, and let the
derivation be the fallback rather than the authority.

The remaining three findings were the same class in the identity half:
`alias_attached!` recorded an attachment nothing had performed — it now demands the
aliases the caller actually read off the container, because recording is what
switches `connect_host`; `assigned_container_name?` asked whichever app came back
first, so a shared cluster named after one of its tenants read as dedicated — it
now requires that the cluster have exactly one app; and `DedicatedDbProvisioner`
passed the *base* name, creating `appone` rather than `appone_production`.

## Amendment (2026-09-05): the third round, and what it says about the first two

A third adversarial pass found six more, and the shape did not change: **each fix
had solved the instance and left the class.**

- A `kind` column was added so shared-versus-dedicated stopped being inferred — and
  **nothing wrote it**. Both production paths now declare what they create
  (`DedicatedDbProvisioner` → `"dedicated"`, `RegisterDatabaseClusterTool` →
  `"shared"`), because a column nothing populates changes nothing.
- `alias_attached!` was made to demand evidence, then still accepted the evidence as
  an argument — which only moves the assertion up one frame. It now observes and
  there is no way to tell it otherwise. Its observation was also aggregating aliases
  across *every* attached network, which would certify a hostname the app cannot
  resolve.
- The denylist conflated *reserved SQL keywords* with *names that already exist*,
  and so refused `users`, `admin` and `root` — perfectly legal identifiers — while
  missing `limit`. Split: postgres-owned names, the cluster's actual admin role
  (checked against the cluster, not guessed), and the real reserved-word list.
- The compatibility audit reported only apps whose derivation returned `nil`,
  missing long names that changed but stayed non-nil, unlinked `Database` rows, and
  stored identifiers the new guard would refuse.
- The memo was keyed on slug and name, but the result also depends on the app's id
  and on every older sibling's name. It was removed rather than re-keyed: any key
  short of "the whole organization" is the same stale-derivation bug one scope
  smaller.

And one that was not a naming defect at all — the guard had been applied to the
delete path, making existing databases undroppable while the controller destroyed
the record anyway. That is [ADR 0012](0012-a-creation-policy-must-not-govern-deletion.md).

A fourth round found six more, and two are worth naming because they are not the
same defect one level in — they are defects the *tests could not see*:

- **The new MCP actions were missing from read authorization.** A read-scoped token
  could not call them. The tests exercised the tool class directly and so never
  crossed that gate — so the feature was invisible to precisely the caller it exists
  for, an agent following a citation mid-diagnosis.
- **The reserved-word list was recalled rather than transcribed**, and omitted
  `join`, `like`, `is`, `full`, `left`, `right`, `natural`, `cross`, `binary`,
  `authorization`, `similar`, `tablesample` and the `current_catalog` family. It is
  now copied from the PostgreSQL keyword table. Separately, the admin-role check was
  applied to database *names* as well as roles, refusing a legal database for a
  collision that only exists in the role namespace.

Also: the alias timestamp recorded no network, so an alias observed on any network
certified the hostname globally — `connect_host` now takes the network the caller
will resolve from, and the observed network is persisted alongside the timestamp.

**What four rounds establish:** the first fix addresses what was reported; the
second addresses what the first fix broke; the third finds that the second was
cosmetic in four places. Tests passed at every stage, because tests assert what was
intended. Only an adversary re-reading the *current* code finds the difference
between a fix and the appearance of one — and a test written by the same hand as
the fix inherits its blind spot, which is why the authorization gap survived a
green suite.

## Status detail

| Step | State |
|---|---|
| Decision recorded | Done — this ADR |
| One naming convention, used by UI and MCP | **Done** — `App#database_name` / `#database_username` |
| MCP omit-`name` path defaults from `app_id` | **Done** — the convention lives in the tool, not only in its schema |
| 63-byte limit, reserved words, collisions | **Done** — fall back to `app_<id>` rather than derive harder |
| A provisioned app keeps the name it was given | **Done** — the record wins over the derivation |
| `alias_attached!` requires evidence | **Done** — observes the container, network-scoped; raises `AliasNotAttached` |
| Cluster `kind` declared by both creation paths | **Done** — inference only for rows predating the column |
| Creation policy kept off the delete path | **Done** — ADR 0012 |
| Compatibility audit | **Done** — `rake database_naming:audit`; must be run against production |
| `cluster-<id>` assigned key | **Done** — `DatabaseCluster#resource_key` |
| Dedicated clusters left alone (already assigned) | **Done** — `#assigned_container_name?` asks the app |
| `database_url` uses the alias for shared clusters | **Done**, gated on `network_alias_attached_at` |
| Attaching the alias to an existing container | Not built — needs a deliberate operator action; reconnecting a live DB container's network is a real interruption |
| Alias attached automatically at cluster creation | Not built |
| Transfer plan names the target by assigned identity | Not built |

Related: ADR 0004 (identity is assigned, never derived — the principle this
applies), ADR 0010 (derived state declares its refresh),
`docs/architecture/derived-state.md`.
