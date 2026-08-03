# Development Docs Index

Development docs are lightweight summaries and process notes. The canonical product requirements live in `docs/plans/`, and current-state truth lives in `docs/analysis/`.

## Project Docs

| File | Purpose | Update when... |
| --- | --- | --- |
| `docs/dev/ROADMAP.md` | Compact build-order summary derived from plans and analysis | Delivery order changes |
| `docs/dev/CHANGELOG.md` | Lightweight shipped-history summary with links to session logs | Notable changes ship |
| `docs/dev/FEATURES.md` | Current shipped foundation and next major capabilities | Product reality changes materially |
| `docs/dev/RALPH-METHODS.md` | Spec template/process for features | The process changes or new examples are added |
| `docs/dev/CONDUCTOR-DEV-LOOP-PROMPT.md` | Auditable loop prompt for completing one Conductor roadmap slice at a time | Loop stop conditions or verification rules change |
| `docs/dev/adr/` | Architecture Decision Records (numbered, one decision each) | A cross-cutting architectural decision is made, reversed, or superseded |
| `docs/dev/audit-duplication.md` | Duplication / "many ways to do the same thing" audit with prioritized consolidation plan | Duplication is meaningfully reduced or a new pattern proliferates |
| `docs/dev/SECURITY-BACKLOG.md` | Known unfixed security weaknesses, their interim mitigation, and what a real fix needs | A weakness is found, mitigated, or fixed |
| `docs/dev/RELEASE-TRUTH.md` | How Conductor knows what is actually deployed and backed up (ReleaseDriftDetector + BackupRun) | Drift statuses, detection rules, or the backup run lifecycle change |
| `docs/dev/THREADS.md` | Living agent↔agent thread convention (local pointer to the dev-docs canon) | The thread loop or roster rules change |

## Architecture Decisions (ADR)

| ADR | Status | Decision |
| --- | --- | --- |
| [`0001`](adr/0001-self-describing-kamal-deploys.md) | **Accepted** | Conductor-managed Kamal deploys must emit self-describing config: all non-secret values materialized in-repo; secrets in Kamal secrets or behind a documented localvault pointer — never stale placeholder defaults |
| [`0002`](adr/0002-caddy-standard-edge.md) | **Rejected** | Caddy superseding kamal-proxy would force Conductor to rebuild kamal-proxy's zero-downtime deploy handoff — reinventing battle-tested functionality. kamal-proxy stays the edge; Caddy is *added* narrowly for dynamic subdomains, never a replacement |
| [`0003`](adr/0003-one-deploy-path-kamal-as-contract.md) | **Accepted** | One deploy path owned by Conductor. Kamal is retained as an *artifact contract* (SHA-tagged images, container labels, retained releases) and an *ops CLI* (rollback/logs/exec/console) — not as the deploy driver. Edge is an independent axis |
| [`0004`](adr/0004-stable-resource-ids-and-infra-revisions.md) | **Proposed** | Identity is assigned, never derived: every app owns a stable `app-<id>` resource key, plus an `infra_revision` that versions *infrastructure shape* separately from code — making residue mechanically detectable |

## Authoring Notes

- Keep content specific to Conductor (VMs, R2 backups, Active Storage).
- Use checklists and explicit steps.
- Link to plan, analysis, and session docs instead of duplicating detail.
