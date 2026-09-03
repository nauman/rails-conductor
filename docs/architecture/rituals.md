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

## The library today — 9 recipes, 2 categories

**Shape recipes** answer *"how do I operate an app of this form?"* `FleetCanon`
maps an app's `{artifact, driver, edge}` to exactly one.

| Recipe | Steps | Shape |
|---|---|---|
| `caddy-mode-app` | 6 | kamal artifact, host Caddy edge, proxy off |
| `kamal-proxy-app` | 4 | kamal artifact, kamal-proxy edge |
| `external-driver-app` | 4 | Conductor does not deploy it |
| `plain-docker-app` | 3 | Conductor-driven docker |
| `native-app` | 3 | host process, systemd |

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

### 1. Rituals are cited but not retrievable

**This is the important one, and it makes ADR 0007 half-built.** A finding carries
`recipe_id: "diagnose-live-orphan"`. There is **no MCP tool that lists recipes or
fetches one**. `conductor_runbook` operates on an app's own checklist, not the
library.

So an agent receives a pointer it cannot dereference through the same channel that
gave it. The pointer was built; the lookup was not. A citation nobody can follow is
a slightly better `remedy` string, not a ritual.

Needed: `list` (the library, with which are custom) and `get` (one recipe with its
description and checklist).

### 2. Nothing covers standing up a NEW app

Every recipe is for an app that already exists — five shapes and four symptoms.
There is no ritual for **onboarding**: create the app, provision its database,
wire env vars and secrets, register the domain and DNS, choose the edge, run the
first deploy, verify.

That is the highest-traffic procedure Conductor has and the one most likely to be
performed by someone who has not done it before. Today an agent asked to deploy a
new app gets `docs/skills/conductor/SKILL.md` — which is a **tool surface
reference**: ten flat tools, their actions, and which mutate. It answers *what can
I call*, never *what order, and what is easy to get wrong*.

The distinction matters and is the whole premise of ADR 0007. The skill is the API;
the ritual is the procedure. An onboarding ritual would carry things the tool list
cannot: that the edge is a server property independent of the artifact, that a
secret belongs in `env: secret:` and not `clear:` (a live credential reached a log
that way), that the first deploy records `build_host` and until then it reads
"not recorded yet".

### 3. No way to read the library outside Ruby

There is no UI and no CLI listing. `FleetRecipes::RECIPES` is a Ruby constant, and
an operator's own edits live in jazari's tables with no surface to read them back.
"Which rituals exist, and which have we customised?" currently requires a console.

Read-only is the useful minimum; editing can follow.

## Adding a ritual

1. Decide the category — shape (a form of app) or diagnostic (a symptom).
2. Write the **hidden truth** into the description. A checklist that explains itself survives an operator who disagrees with it; one that does not gets ignored rather than corrected.
3. Order the checklist so the cheapest discriminating check runs first. `diagnose-live-orphan` leads with a one-query hostname count because it separates "one live copy" from "more than one" before anything expensive.
4. Give steps stable string ids — an id is how MCP addresses a step, so it must survive an edit to the text.
5. If a finding should cite it, add the mapping keyed on the **specific cause**, never an umbrella kind.
6. Seed it: recipes added after the original seed migration need their own, because create-if-missing means the first migration will not run again.

## Related

- [ADR 0007](../dev/adr/0007-findings-cite-rituals.md) — a finding must cite its ritual
- [ADR 0010](../dev/adr/0010-derived-state-declares-its-refresh.md) — derived state declares its refresh
- [`derived-state.md`](derived-state.md) — the sibling inventory
- `docs/skills/conductor/SKILL.md` — the tool surface, which is not a ritual
