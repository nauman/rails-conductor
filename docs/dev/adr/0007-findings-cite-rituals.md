# 0007. A finding must cite the ritual that resolves it

Date: 2026-08-27

## Status

**Accepted (2026-08-27).** Mechanism decided; the diagnostic recipes are seeded
incrementally as incidents produce them. See status below.

## Context

Resolving the fifteen-day orphan of ADR 0006 took a long chain of steps: read the
failed deploy's log, notice the stop-first line, compare the app repo's
`builder.remote` against Conductor's record, inspect the container's restart
policy and creation date, read its logs to establish it had run for fifteen days
rather than since the reboot, count distinct hostnames in `solid_queue_processes`
to prove a second live copy, and check `RecurringExecution` uniqueness to
establish that duplicate *enqueues* were not the risk but duplicate *execution*
was.

Every one of those steps was reconstructed from scratch, in a session, by
guessing what to look at next. None of it is retrievable. **The next agent to
meet the same symptom starts exactly as blind**, and the operator watches the
same archaeology happen again.

The sharper version of the complaint, and the one that matters: **MCP surfaced
the finding and could not tell anyone what to do about it.** `situation` reported
a `dead_container` for this app on the first read of the session. It did not, and
could not, report the live orphan sitting beside it — and when the orphan was
eventually found by hand, MCP had nothing to say about how to confirm it, what
made it dangerous, or how to stop it in a way that survives a reboot. The control
plane knew *that* something was wrong long before it could say *what to do*.

Conductor already solved this problem once, for a different axis. `FleetCanon`
maps an app's shape to a jazari recipe, `FleetRecipes` holds the steps, and
`situation` hands every app a `recipe_id` with checklist progress. That machinery
is good, and it is **keyed on what an app IS, never on what has gone wrong with
it.** Findings got a `detail` and a one-line `remedy` string instead:

```ruby
items << attn("residue", app, detail: ..., remedy: app.residue.first[:remedy])
```

A one-line remedy is enough when the fix is `docker rm <name>`. It is not enough
when the honest answer is "prove this is what you think it is, then act, then
prove it worked" — which is every finding worth having.

## Decision

**Every finding names a jazari recipe, and the diagnostic knowledge lives in that
recipe rather than in an agent's session.**

Three parts:

### 1. Findings carry `recipe_id`, not just `remedy`

`attn(...)` gains a recipe pointer resolved from the SPECIFIC cause, never the
presentation kind. `blocked_deploy` and `release_drift` are umbrellas — a deploy
blocks on holds, failed seeds, a missing port or an at-risk audit, and drift
covers four release states including "the box could not be read". Mapping the
umbrella would hand three of four readers a ritual for someone else's problem,
which is the failure this ADR exists to prevent. An unmapped cause carries nil.
`remedy` stays
— it is the one-line summary — but it stops being the whole of what Conductor
knows. An agent reading `situation` can then fetch the ritual and follow it
without having met the problem before.

### 2. Diagnostic recipes are a first-class recipe kind

Existing recipes answer *"how do I operate this shape?"* Diagnostic recipes
answer *"this symptom appeared — how do I confirm it, and what do I do?"* They
carry the checks in the order that discriminates fastest, and they say what each
check rules out. The orphan recipe, for instance, leads with the
`solid_queue_processes` hostname count because it is one query, needs no labels,
and separates "one live copy" from "more than one" before anything expensive.

### 3. Rituals live in jazari, and incidents are what write them

Recipes are data in `FleetRecipes`; jazari owns the API. Seeding stays
create-if-missing, so an operator's edit is never clobbered. **When an incident
is resolved, the steps that resolved it become a recipe in the same change.** A
diagnosis that stays in a session transcript is a diagnosis the fleet did not
learn.

## Consequences

**Accepted:**
- A new finding kind ships with a recipe, or it ships knowing it has none. An
  unpinned finding is a notification, and notifications train people to scroll.
- Resolving an incident is not finished when the box is healthy. It is finished
  when the next person meets it with instructions.
- Recipes will disagree with reality over time. That is why they carry the
  incident that produced them: a step that explains itself can be argued with,
  and a step that cannot be argued with gets ignored instead of corrected.

**Costs:**
- Writing a recipe at the end of an incident is exactly when nobody wants to.
  This is the cost, and it is the whole point — the alternative is paying the
  archaeology again at a worse moment.
- Recipes keyed on finding kind will not cover novel symptoms. Those get
  diagnosed the hard way, once, and then pinned.

**Rejected:**
- *Longer `remedy` strings.* A remedy answers "what do I type". It cannot carry
  ordering, discrimination, or what a check rules out — and prose in a field
  nothing verifies drifts silently.
- *A separate diagnostics system.* jazari is the shared runbook layer for every
  repo. A second one would be a second place to look, and looking in the wrong
  place is the failure being fixed.
- *Documentation instead of recipes.* Docs are not addressable from MCP. An agent
  holding a finding needs the ritual attached to that finding, not a path to read.

## Status detail

| Step | State |
|---|---|
| Decision recorded | Done — this ADR |
| `live_candidate` diagnostic recipe seeded | Done — `FleetRecipes` |
| `attn(...)` carries `recipe_id` per finding | Done — resolved from the SPECIFIC cause, never the umbrella kind |
| Recipes for release drift, build placement, deploy hold | Done — `FleetRecipes` |
| Rituals for the other block causes (failed seed, missing port, at-risk audit) | Not built — those findings correctly carry no recipe |
| Rituals for `mixed_release` and `unknown` release states | Not built — deliberately unmapped rather than pointed at the drift ritual |

Related: ADR 0006 (the orphan this came from), ADR 0005 (host-side transactions),
`FleetCanon` (shape → recipe, the machinery this extends to findings).
