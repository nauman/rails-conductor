# Rituals

> **The decisions are [ADR 0007](../dev/adr/0007-findings-cite-rituals.md)** (a finding
> must cite the ritual that resolves it) **and `FleetCanon`** (an app's shape resolves
> to a recipe). This page is the inventory: what rituals exist, how they reach an
> agent, and what is missing.

## What a ritual is, and who owns it

A **recipe** is an ordered procedure with the reasoning attached: a topic, a
description carrying the *hidden truth* of that shape, and a checklist of steps.
jazari owns the API — `Jazari::RecipeRegistry`, runs, checklists, revision guards.
`FleetRecipes` owns the **content**, because recipes are data and baking fleet
specifics into a shared gem would make every ritual fix a gem release.

Seeding is **create-if-missing**, so an operator's edit is never overwritten. Once
edited, `situation` reports that subject as `state: "custom"`, `diverged: true` —
it no longer tracks the canon, and several already don't.

## The library today — 10 recipes, 3 categories

**Shape recipes** answer *"how do I operate an app of this form?"* `FleetCanon`
maps an app's `{artifact, driver, edge}` to exactly one.

| Recipe | Steps | Shape |
|---|---|---|
| `caddy-mode-app` | 6 | kamal artifact, host Caddy edge, proxy off |
| `kamal-proxy-app` | 4 | kamal artifact, kamal-proxy edge |
| `external-driver-app` | 4 | Conductor does not deploy it |
| `plain-docker-app` | 3 | Conductor-driven docker |
| `native-app` | 3 | host process, systemd |

**The onboarding recipe** answers *"how do I stand up an app that does not exist
yet?"* — `onboard-new-app`, 10 steps. It is the only recipe not about an app that
already exists, and the only one reached by asking for it rather than by being
cited.

**Diagnostic recipes** answer *"this symptom appeared — how do I confirm it, and
what do I do?"* Added per ADR 0007; each was written from an incident.

| Recipe | Steps | Symptom |
|---|---|---|
| `diagnose-live-orphan` | 10 | this app may be running twice |
| `diagnose-release-drift` | 5 | Conductor's record disagrees with the box |
| `diagnose-build-placement` | 5 | builds on a machine that serves traffic |
| `diagnose-deploy-hold` | 5 | held, and the reason may be stale |

Five finding kinds map to a ritual (`FleetRecipes::FINDING_RECIPES`). Umbrella
kinds deliberately resolve from the specific cause, never the presentation kind —
`blocked_deploy` only cites the hold ritual when a hold is actually the blocker.

## Gaps

### 1. Rituals are cited but not retrievable — **closed**

A finding carried `recipe_id: "diagnose-live-orphan"` into a channel with nothing
that could dereference it. The pointer was built; the lookup was not, which made
ADR 0007 half-built — a citation nobody can follow is a slightly better `remedy`
string, not a ritual.

`conductor_runbook` now answers both halves: `list_rituals` (the library, flagging
which have been customised) and `get_ritual` (one recipe with its description and
addressable steps). They live on the runbook tool because a ritual and a runbook
are the same kind of thing at two scopes — the library procedure, and this app's
copy of one.

Two things worth knowing about it:

- **An unknown id is a failure, not an empty ritual.** jazari answers a missing
  recipe with a content-free `EMPTY` record rather than raising, so passing that
  through would answer a typo with a valid-looking ritual that has no steps.
- **The library is deliberately global, not per-organization.** Recipes describe how
  to operate Conductor, not tenant data, and jazari's table has no organization
  column. On a multi-tenant install one operator's customisation is visible to all —
  acceptable for procedure text, and stated here rather than discovered.

### 2. Nothing covers standing up a NEW app — **closed**

`onboard-new-app` now covers it: create the app, pick the edge, provision the
database, wire env vars and secrets, register the domain and DNS, deploy, verify.

It is the highest-traffic procedure Conductor has and the one most likely to be
performed by someone who has not done it before. An agent asked to deploy a new app
previously got only `docs/skills/conductor/SKILL.md` — a **tool surface reference**:
ten flat tools, their actions, and which mutate. It answers *what can I call*, never
*what order, and what is easy to get wrong*.

The distinction matters and is the whole premise of ADR 0007. The skill is the API;
the ritual is the procedure. So the recipe carries what the tool list cannot: that
the edge is a server property independent of the artifact, that a secret belongs in
the secret list and not the clear one (a live OAuth credential reached a log that
way) **and that this is only structural on the kamal path**, that provisioning
should omit `name` and let the convention choose, and that `build_host` is recorded
by the first deploy — until then "not recorded yet" is not the same as "builds on
the app server".

### 3. No UI for the library — **open**

MCP can now read it, but a human still cannot. `FleetRecipes::RECIPES` is a Ruby
constant and an operator's edits live in jazari's tables, so "which rituals exist,
and which have we customised?" is answerable by an agent and not by a person.

Read-only is the useful minimum; editing can follow.

## Adding a ritual

1. Decide the category — shape (a form of app) or diagnostic (a symptom).
2. Write the **hidden truth** into the description. A checklist that explains itself survives an operator who disagrees with it; one that does not gets ignored rather than corrected.
3. Order the checklist so the cheapest discriminating check runs first. `diagnose-live-orphan` leads with a one-query hostname count because it separates "one live copy" from "more than one" before anything expensive.
4. Give steps stable string ids — an id is how MCP addresses a step, so it must survive an edit to the text.
5. If a finding should cite it, add the mapping keyed on the **specific cause**, never an umbrella kind.
6. Seed it: recipes added after the original seed migration need their own, because create-if-missing means the first migration will not run again. This has now caught three times (`20260827030000`, `20260905000003`) — a recipe that exists only in Ruby is invisible to every reader.

## Related

- [ADR 0007](../dev/adr/0007-findings-cite-rituals.md) — a finding must cite its ritual
- [ADR 0010](../dev/adr/0010-derived-state-declares-its-refresh.md) — derived state declares its refresh
- [`derived-state.md`](derived-state.md) — the sibling inventory
- [`01-builder/`](01-builder/README.md) — where an image is built, and who decides
- `docs/skills/conductor/SKILL.md` — the tool surface, which is not a ritual
