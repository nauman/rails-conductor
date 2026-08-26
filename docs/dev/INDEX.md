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
| [`0003`](adr/0003-one-deploy-path-kamal-as-contract.md) | **Superseded** | Historical one-path decision; current contract uses Kamal for Kamal artifacts on both Caddy and Kamal-proxy boxes, with edge-specific health/proxy behavior |
| [`0004`](adr/0004-stable-resource-ids-and-infra-revisions.md) | **Proposed** | Identity is assigned, never derived: every app owns a stable `app-<id>` resource key, plus an `infra_revision` that versions *infrastructure shape* separately from code — making residue mechanically detectable |
| [`0005`](adr/0005-host-side-transactions-for-interruptible-ops.md) | **Accepted** | Classify every privileged op by what an interruption leaves behind; ops that take a resource away before giving it back need a host-side transaction (lock, verified completion, an executor that outlives the caller), because neither a defensive script nor a background job survives its own process dying |
| [`0006`](adr/0006-a-running-container-must-be-nameable.md) | **Accepted** | Temporary containers get temporary lifecycles (candidates never `unless-stopped`), and Conductor must be able to say why every running container is running — a live orphan looks healthy and is the dangerous kind; more than one distinct hostname in `solid_queue_processes` is the cheapest detector |

## Authoring Notes

- Keep content specific to Conductor (VMs, R2 backups, Active Storage).
- Use checklists and explicit steps.
- Link to plan, analysis, and session docs instead of duplicating detail.
