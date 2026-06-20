# 00 · Conductor delivery sequence — 14 slots, 4 waves

**Decision surface:** [`00-delivery-sequence.html`](./00-delivery-sequence.html) — interactive: foundation-audit donut, wave gantt, per-wave bar chart, dependency graph, 14-entry filterable table. **Open this to scan or sequence.**

> ↪ **Filed 2026-06-20 as a delivery overlay, not a renumber.** The `plan-*.html` pages in `docs/roadmap/` are authoring order (when each gap got specced). They are NOT a delivery order. This file groups them into dependency **waves** so backlog work has a sensible pick order. Plan IDs stay stable; waves are an overlay, not a rewrite.

## Why this exists

Reading [`backlog.md`](./backlog.md) top-to-bottom by priority mis-orders the build:

- **Kamal control machine** (slot 01) and **GitHub App** (slot 02) are **shipped** — they're the foundation everything else builds on.
- **Seed management** (slot 08) reads as a standalone P1, but it **depends on the in-container task runner** (slot 09) to actually run `db:seed`.
- **Multi-tenant MCP** (slot 14) is what makes "anyone can deploy" real, but it's late-numbered.

Without an overlay, an engineer builds seed-management before the task runner it needs. This file replaces "priority = pick order" with "wave = dependency tier."

## The waves at a glance

| Wave | Theme | Slots |
|---|---|---|
| **0** | Foundation — must ship first (shipped ✅) | 01 · 02 |
| **1** | Close the push → deploy loop | 03 · 09 |
| **2** | Operational parity (depends on W1) | 04 · 05 · 06 · 08 · 10 |
| **3** | Breadth & scale | 07 · 11 · 12 · 13 · 14 |

**Graph plots 14 entries** — all 14 plan slots (01–14). Each wave is a **dependency tier**, not a sprint; slots inside a wave can be built in parallel.

## Wave 0 close-out — done

Wave 0 is **shipped and live-validated** (2026-06-19): the KamalDeployer control-machine path builds over SSH and deploys (wiseherds + kuickr proven), and the GitHub App + deploy-key clone auth works. Wave 1 is unblocked.

## Wave 1 close-out — blocks Wave 2

1. **W1-A · `03` auto-deploy-on-push** — webhook → deploy. Needs the GitHub App webhook (slot 02) wired to `deploy_app`. The signature Hatchbox loop; everything operational rides on a deploy actually being triggerable hands-free.
2. **W1-B · `09` in-container task runner** — run `db:seed`/`rake`/`migrate` in the app container via UI + MCP. Slot 08 (seed-management) is blocked on it.

## How to read the HTML

- **Foundation audit donut** — Wave 0 slots + shipped verdicts.
- **Wave gantt** — one bar per wave (W0..W3), temporal sequencing.
- **Per-wave bar chart** — slot count per wave; surfaces imbalance.
- **Dependency graph** — columns by wave; arrows = "this slot depends on that one." Click a wave-chip to dim others.
- **Filterable table** — every slot; filter by wave.

## How this stays in sync

- When a slot moves between waves, edit `ITEMS` in `00-delivery-sequence.html` AND the wave table above.
- When a new plan is added, append to `ITEMS` (`id`, `title`, `status`, `wave`, `deps`) AND bump the title counts (`14 slots`, `14 entries`).
- When a slot ships, status flips `spec → partial → shipped`; wave assignment doesn't change post-ship.
- Treat the counts as one fact stated in three places (title, accounting line, ITEMS length) — change all three together, `.md` and `.html`, in one commit.

## See also

- [`backlog.md`](./backlog.md) — the spine (what each slot is, priority, effort).
- Per-slot detail: `plan-kamal-control-machine.html` · `plan-github-app.html` · `plan-auto-deploy-push.html` · `plan-rollbacks.html` · `plan-background-workers.html` · `plan-app-logs.html` · `plan-server-provisioning.html` · `plan-seed-management.html` · `plan-app-task-runner.html` · `plan-deploy-hooks.html` · `plan-web-console.html` · `plan-alerts.html` · `plan-accessories.html`.
