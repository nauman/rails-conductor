# Database conventions

> **The decision is [ADR 0011](../dev/adr/0011-a-database-is-reached-by-an-assigned-alias.md).**
> This page is how it works in practice: how a database is named, how an app reaches
> it, what is still migrating, and which bugs each rule exists to prevent.

## Two questions, often confused

Provisioning a database answers two separate questions, and conflating them is what
produced the bugs below:

- **What is it called?** A name in postgres. Must be a legal identifier, must be
  predictable, must be the same whoever asks for it.
- **How is it reached?** A host in a connection string. Must be resolvable by Docker
  DNS, and must survive anything a human renames.

The first is a **convention**. The second is an **identity**. A convention can be
derived; an identity must be assigned.

## Naming

`App#database_name` and `App#database_username` are the single source. Both the UI
and the MCP tool use them.

```
slug              database              role
my-app       →    my_app_production        my_app
some.site    →    some_site_production     some_site
79-thing     →    app_79_thing_production  app_79_thing
```

Once a database has been provisioned, **the recorded name wins**: `database_name`
returns the `Database` row's own name and only derives when there is nothing to
return. A derivation that keeps running after it has produced a fact will
eventually disagree with it — a slug edit would aim the next provision at a new,
empty database while the app's data stayed behind, and nothing compares the two.

Rules, and why each exists:

- **Everything outside `[a-z0-9_]` collapses to `_`.** These names reach
  `CREATE DATABASE` and `CREATE ROLE` as *interpolated SQL*. The derivation has to
  produce a legal identifier **by construction**, not by luck — `validate_identifier!`
  is the second line of defence, not the first.
- **A leading digit gets an `app_` prefix.** Postgres will not accept an unquoted
  identifier starting with a digit, and quoting it would make every later reference
  case-sensitive.
- **The role matches the database's base name.** One app, one role, one database.
- **63 bytes, including the suffix.** Postgres truncates identifiers there, so the
  budget is `63 - len("_production")` and a name that needs shortening carries the
  app's id — truncating alone would manufacture the collision the limit exposes.
- **A name that cannot be trusted falls back to `app_<id>`.** Reserved keywords
  (`select`, `order`), the administrative roles that already exist on every cluster
  (`postgres`, `conductor`), an empty derivation, or a base another app claimed
  first. Deriving harder would only produce a name that looks right and points at
  someone else's database.
- **On a collision, the older app keeps the plain name.** Its database already
  exists; the newcomer gives way. This is what makes the name stable rather than
  dependent on who asks.

### The bug this fixed

Two provisioning paths disagreed. The UI derived the names; the MCP tool *required*
a caller-supplied `name` and had no default at all. So **the path most likely to
provision a brand-new app — an agent — was the one with no convention**, and named
databases by hand.

A convention only one caller follows is a preference. The MCP tool now defaults from
`app_id`, and an explicit `name` means only "create it under a different name" —
provisioning always runs `CREATE ROLE` and `CREATE DATABASE`, so it cannot adopt
something that already exists, and saying otherwise would send a caller down a path
that fails.

## Reachability

The host in `Database#database_url` is `DatabaseCluster#connect_host`, and which
name that returns depends on **who chose the container's name**:

| Cluster kind | `container_name` | Host used | Why |
|---|---|---|---|
| **Dedicated** | `app-<id>-db` (or legacy `<slug>-db`) | the container name | Conductor assigned it; already stable |
| **Shared**, alias attached | operator-typed | `cluster-<id>` | typed names are editable |
| **Shared**, alias not yet attached | operator-typed | the container name | the alias does not exist yet, so nothing would resolve |

`assigned_container_name?` decides this by **asking the app**
(`dedicated_db_container_candidates`), never by pattern-matching the name's shape.
That distinction is the point: a first implementation tested `/app-\d+-db/`, missed
the legacy `<slug>-db` spelling, and would have re-hosted a cluster that was already
stable. Guessing whether a name is trustworthy from how it looks is the same
fragility being removed.

### The bug this prevents

A shared cluster's `container_name` is typed at `register_cluster` and editable
afterwards, while also being the DNS name every dependent app resolves. Renaming it
silently broke the **next** deploy of every app on it — not the running app, because
the URL is re-derived each deploy. That bound is real and it is also what makes the
failure confusing: nothing breaks when the change is made, and the deploy that fails
is a later one, for a reason no longer in anyone's memory.

Transfers are the sharp case. Source and target are different cluster records on
different hosts, and the runner replicates `source_url → target_url` — both derived
from typed names, on the one operation where live data is in flight.

## Migration state

The switch is **gated**. `connect_host` returns the alias only once
`network_alias_attached_at` is set, because the alias has to exist on the container
before anything resolves it — switching first would break every app on a shared
cluster at once, which is worse than the rename it prevents and arrives all
together.

**Not built yet:** attaching the alias to a running container. That means
`docker network disconnect` + `connect --alias`, which briefly interrupts a live
database's connectivity — a deliberate operator action, never a side effect of a
read. Until then, existing shared clusters behave exactly as before.

## Provisioning, end to end

1. `DatabaseCluster#provision_database!` generates a 24-byte password, creates the
   `Database` row `pending`, then runs two statements: `CREATE ROLE … LOGIN PASSWORD … CREATEDB`
   and `CREATE DATABASE … OWNER …`.
2. On success the row goes `active`; on failure it is marked `error` before
   re-raising, so a half-provisioned database is visible rather than silent.
3. The app receives `DATABASE_URL` **derived at deploy**, never baked into an image
   — which is why a rename breaks the next deploy rather than the running app.

## Related

- [ADR 0011](../dev/adr/0011-a-database-is-reached-by-an-assigned-alias.md) — the decision
- [ADR 0004](../dev/adr/0004-stable-resource-ids-and-infra-revisions.md) — identity is assigned, never derived
- [`derived-state.md`](derived-state.md) — the sibling inventory
