# Documentation Index

> Doc anchors for Conductor.

## Start Here

- **`docs/ARCHITECTURE.md` — READ FIRST. The deployment matrix (3 runtimes × Caddy edge × topology) with mermaid diagrams. Understand this before touching deploy code.**
- `docs/README.md` — overview and structure
- `docs/USAGE.md` — how to use Conductor (web UI, API, MCP, chat)
- `docs/PILLARS.md` — the seven product pillars and where help is wanted
- `AGENTS.md` — collaborator rules and doc maintenance

## Library Map

| Section | Doc | Purpose |
| --- | --- | --- |
| **Architecture** | **`docs/ARCHITECTURE.md`** | **The deployment matrix (Docker/Native/Kamal × Caddy edge × standalone/fleet) with mermaid diagrams — read first** |
| Usage | `docs/USAGE.md` | Getting started and the web UI / API / MCP / chat surfaces |
| Pillars | `docs/PILLARS.md` | Seven pillars, current maturity, and contribution entry points |
| Agents | `docs/agents/00-roster.md` | The `awaiting:` address book — read first on boot; names usable in thread headers |
| Agents | `docs/agents/staff_engineer.md` | Engineering brief: TDD-first, vanilla-Rails/Hotwire defaults, Conductor conventions |
| Agents | `docs/agents/deploy.agent.md` | Deploy agent: GHCR CI backbone, kamal-proxy edge, `localvault` secrets, `/version` verify |
| Threads | `docs/threads/` | Living agent↔agent conversations (`<topic>.thread.md`); convention in `docs/dev/THREADS.md` |
| Learnings | `docs/learnings/` | Hard-won manual-ops learnings → Conductor feature blueprints (e.g. multi-app-hosting) |
| Architecture | `docs/architecture/` | Cross-cutting design notes too long for an ADR — start with `derived-state.md` (what Conductor caches, what refreshes it, where the gaps are) |
| Code learnings | `docs/code_learnings/INDEX.md` | Durable project operating rules, including Kuickr-first visual review |
| Infrastructure | `docs/infra/INDEX.md` | VM/Kamal/Caddy/R2/Active Storage ops docs |
| Development | `docs/dev/INDEX.md` | Roadmap, changelog, features, and spec method |
| Development | `docs/dev/CONDUCTOR-DEV-LOOP-PROMPT.md` | Auditable loop prompt for completing one Conductor roadmap slice at a time |
| Decisions (ADR) | `docs/dev/adr/` | Architecture Decision Records — cross-cutting decisions, one per file (e.g. 0001 self-describing Kamal deploys) |
| Plans | `docs/plans/INDEX.md` | Master PRD map and capability plans by pillar |
| Plan | `docs/plans/01-client-access-managed-billing.md` | Resource-scoped clients, prepaid managed backups, and server-space resale |
| Scenarios | `docs/scenarios/INDEX.md` | User-driven use cases with actors and flows |
| Scenario | `docs/scenarios/sc-008-beta-access.md` | Hosted beta intake: waitlist, manual approval, and free access guardrails |
| Scenario | `docs/scenarios/sc-010-client-access-managed-billing.md` | Per-client resource access, wallet, backups, and server-space billing |
| Approved specs | `docs/superpowers/specs/INDEX.md` | Reviewed design records linked to canonical numbered plans |
| Status | `docs/STATUS.md` | Current shipped/partial/missing product reality |
| Analysis | `docs/analysis/pillars-audit-2026-03-19.md` | Historical March 2026 baseline; not current status |
| Sessions | `docs/sessions/INDEX.md` | Session-level implementation history and current handoff docs |
| Scripts | `docs/scripts/agent-thread-status.sh` | Read-only report of thread obligations (OWED BY ME / WAITING ON OTHERS) |
| Scripts | `docs/scripts/ralph-doc-loop.md` | Minimal doc update loop |
| Scripts | `docs/scripts/ralph-doc-prompt.sh` | Emits a compact prompt for doc updates |
| Scripts | `docs/scripts/ralph-doc-check.sh` | Sanity checks for required docs |
| Scripts | `docs/scripts/docs-doctor.rb` | Canonical docs gate (delivery-sequence components + link integrity + mirror sync); runs in CI |

## How to Use

- Keep docs concise, actionable, and project-specific.
- Prefer checklists and ordered steps.
- Update indexes when adding or renaming docs.
- Use `docs/plans/INDEX.md` as the source of truth for product requirements.
