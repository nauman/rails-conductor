# 10 — Runbook queues and recipes: a name you can always call

Status: **Spec — v1, 2026-08-09. Not started.**

Nodepad shipped per-subject runbooks, then found what they were missing: *a name
you can always call*. Its answer is three layers — a checkable runbook per
subject, **recipes as data**, and **queues** (stable names for rituals that
outlive any single record). Source:
[How a runbook works with a queue](https://inventlist.com/sites/node-pad/series/building-nodepad/parts/runbook-queue).

Conductor has layer 1 and neither of the other two. This spec adds them.

## Where Conductor is today

| Layer | Nodepad | Conductor |
|---|---|---|
| Runbook per subject | board · node · product | **App only** (`apps.deploy_runbook` + `deploy_checklist_items`) |
| Recipes as data | records, operator-editable at runtime | **nothing** — no default, no template, every app's runbook hand-written from zero |
| Queues (ritual aliases) | `kind: "queue", queue: "submissions"` | **nothing** |
| Revision guard | `expected_revision` on every mutation | **nothing** — last writer wins |

`conductor_runbook` requires `app_id`/`app_name` on *every* action. There is no
way to ask Conductor about a ritual that isn't one app's deploy.

## The addressing problem, in our own logs

A runbook attached to a subject is right for truths that belong to one thing.
Some truths belong to a **ritual**, not a record — and ours currently live
anywhere but Conductor:

| Ritual | Where its steps actually live today | What that cost |
|---|---|---|
| Verify a backup by restoring it | `docs/sessions/2026-08-07-…md` prose | 13 green schedules protected nothing for weeks; "verified" meant a checkmark, not a restore |
| Close a session | **an agent's private memory file** | Invisible to every other agent by construction |
| Triage "site down" | nowhere | 2026-08-09: one timed-out probe painted Kuickr red while it served 200 in 0.38s from every vantage point |
| Expect the 04:00 kernel reboot | nowhere | Two agents independently investigated the same unattended-upgrade reboot as a mystery |
| Operate as `deploy`, never `root` | `CLAUDE.md` + a learnings doc + a memory file (three copies) | Root-owned files surface at the *next* deploy, far from the cause |
| Detect residue after a form change | `docs/learnings/form-changes-leave-residue.md` prose | A 502 that "works until it doesn't" |
| Register a DB cluster (supervised creds) | a thread note | Sat waiting because the steps weren't callable |

None of these is one app's deploy. Each is a ritual an operator or agent needs
**at the moment of action**, and Conductor — the control plane that *knows* the
fleet — can't serve any of them. Docs can't either: nothing checks a doc off,
and nothing tells you the doc is current.

## Decisions

**D1. A queue is a stable named alias for a fleet ritual.** Read it by name,
never by hunting a record that happens to carry the truth today:

```
conductor_runbook { action: "get", kind: "queue", queue: "backup-verify" }
conductor_runbook { action: "get", kind: "queue", queue: "incident-triage" }
```

`kind` defaults to `"app"`, so every existing call keeps working unchanged.

**D2. Queues are read-only.** They always serve the ritual's current recipe;
mutations return `read_only_target`. Per-subject customisation still belongs to
the subject — the ritual itself has exactly one editable home (D3).

**D3. Recipes are data, not code.** A `runbook_recipes` table: `slug`, `topic`,
`purpose`, `hidden_truth`, `checklist` (ordered items with `required`), seeded
once and operator-editable at runtime. Fixing a ritual is a data write, not a
deploy. Conductor has no defaults at all today, so this is also what gives a
**fresh open-source install working rituals out of the box** — nothing here may
assume this operator's fleet.

**D4. The content digest is the revision.** Every read carries
`revision = digest(recipe content)`; mutations supply `expected_revision` and are
refused on mismatch. Editing a recipe invalidates outstanding revisions instead
of silently drifting under someone mid-checklist. This repo is a **shared
worktree with concurrent agents** — last-writer-wins is the same defect class as
the git-hygiene collision, and the same fix applies.

**D5. Subjects beyond App.** `apps.deploy_runbook` is a text column; servers and
databases have no runbook at all, though provisioning and restore are exactly
the rituals people get wrong. Generalise to a polymorphic `runbook` per subject
(App, Server, Database) — recipe-backed, per-subject overridable.

**D6. Advisory in v1 — a queue never blocks.** App deploy preflight already
*blocks* on its own checklist; queues stay read-and-check-off only. Gating a
fleet operation on a queue's checklist is a later decision, made once the
rituals have earned trust.

## The queues that ship first

Each one is a ritual this fleet already runs, with steps already proven in
practice — not invented for the spec.

| Queue | Ritual | Recipe seeded from |
|---|---|---|
| `backup-verify` | Prove a backup by restoring it: dump → restore to scratch → table + row counts → demote on failure | the 2026-08-07 session, 11/12 verified |
| `incident-triage` | Probe twice before believing "down"; check from the box; check uptime + kernel reboot; only then wake anyone | the 2026-08-09 false `site_down` |
| `server-provision` | deploy user first; docker group; ownership; never app-level `root` | `CLAUDE.md` + `docs/learnings/operate-as-deploy-not-root.md` |
| `app-onboard` | register → env contract → declare vars where the deploy path reads them → first deploy → verify → backup before DNS | kuickr's env-contract week (3 failed deploys) |
| `form-change` | when deploy method / edge / server / DB changes: enumerate residue, republish the edge, re-verify | `docs/learnings/form-changes-leave-residue.md` |
| `session-close` | session log + INDEX row → `np close --file` → flip the thread | the memory file that shouldn't be a memory file |

## Surfaces

- **MCP** — `kind` + `queue` on `conductor_runbook` (flat enum preserved, per the
  house MCP pattern). One new read, no new tool.
- **CLI** (spec 09) — `conductor runbook queue <name>`, `conductor runbook check <item>`.
  Add the row to `API-COVERAGE.md`; queues are read-only there too.
- **Web** — a Rituals page listing queues with checklist progress; each recipe
  editable in place (the one editable home).
- **`situation`** — a needs-attention row may name the queue that resolves it, so
  the resume point points at the ritual instead of describing the problem.

## Phases

1. `runbook_recipes` + digest revision + `kind: "queue"` read path; seed
   `backup-verify` and `incident-triage`. Read-only, no schema change to apps.
2. `expected_revision` on the existing app-runbook mutations (closes D4 for
   what already ships), plus per-subject overrides resolving against a recipe.
3. Polymorphic subjects (Server, Database) — D5.
4. Web Rituals page + `situation` queue pointers + CLI rows.

## Open questions

- **OQ-1** Does a per-subject override *diverge* from its recipe permanently, or
  rebase when the recipe changes? Nodepad's answer: uncustomised subjects get the
  fix, customised ones keep their edit. Same here — but Conductor should then
  *show* which subjects have diverged, or a stale override is invisible.
- **OQ-2** Do queue checklists have per-run state, or is a queue a template that
  a run instantiates? Backup-verify runs nightly across 12 apps: one shared
  checklist would thrash. Leaning: template + per-run instance keyed to the
  operation, which is also what makes "did last night's ritual complete?"
  answerable.
- **OQ-3** Should `session-close` really be a Conductor queue, or does it belong
  to the agent-docs repo? It is a *development* ritual, not a fleet one — but it
  is also the clearest case of a ritual with no home.
