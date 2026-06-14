# Session: Routing Baseline and Docs Realignment

**Date:** 2026-03-28
**Scope:** 79-Conductor
**Goal:** Bring the docs back in sync with the shipped recurring-ops and Caddy routing baseline, then define the next implementation slice clearly enough to resume feature work

---

## What Was Done

### 1. Captured the shipped recurring-ops baseline

The product now schedules its baseline recurring operations in `config/recurring.yml`:

- `RefreshServerMetricsJob` every 5 minutes
- `SyncContainerStatusJob` every 2 minutes
- `RunScheduledBackupsJob` every minute

This moves recurring metrics refresh, container sync, and backup dispatch out of planning and into implementation.

### 2. Captured the shipped Caddy routing foundation

The March 25 work added a real SSH-backed `CaddyClient` and rewired the domain tools to use it.

Current shipped routing baseline:

- fetch full Caddy config over SSH
- snapshot config before mutation
- list Conductor-managed routes
- upsert or remove routes through the Caddy Admin API
- validate route inputs for TCP and Unix-socket upstreams
- expose a basic route/certificate status surface

This is the service boundary needed to continue the routing plan, but it is not the full routing product yet.

### 3. Realigned the docs to the shipped code

The summary docs and plan index previously described the Caddy client and domain tools as unimplemented or stubbed. They now reflect the shipped baseline and the remaining gap.

Updated docs include:

- `docs/analysis/pillars-audit-2026-03-19.md`
- `docs/dev/ROADMAP.md`
- `docs/dev/FEATURES.md`
- `docs/dev/CHANGELOG.md`
- `docs/plans/INDEX.md`
- `docs/plans/caddy-client.md`
- `docs/plans/routing-caddy.md`
- `docs/INDEX.md`
- `docs/README.md`

### 4. Added session navigation

Created `docs/sessions/INDEX.md` so future session logs have a stable entry point from the main docs map.

---

## Current Implementation Baseline

### Recurring Operations

- Baseline recurring jobs are configured.
- Remaining recurring-ops work is failure surfacing, queue tuning, historical freshness, and broader maintenance workflows.

### Routing and Edge

- `CaddyClient` exists and operates through SSH-executed `curl` against the host-local Caddy Admin API.
- Add/remove domain tools are no longer stubs.
- Route publication is still mostly tool-driven and not yet tied to first-class route records, deployment hooks, reconciliation jobs, or certificate/drift workflows.

### Product Summary

Conductor now has enough routing foundation to start the next real implementation slice. The immediate gap is no longer "build any Caddy client at all." The immediate gap is "turn the baseline client into a durable product workflow."

---

## Next Implementation Slice

### 1. Route State Persistence

- Add a first-class route model or equivalent table
- Persist desired route state, last publish result, and validation timestamps
- Stop treating `app.domain` as the only routing source of truth

### 2. Deploy Lifecycle Integration

- Publish or revalidate routes after successful deploys
- Model Docker port and native socket upstreams explicitly
- Keep route publication visible in deployment state, not a hidden side effect

### 3. Reconciliation and Drift

- Compare desired route state with live Caddy config
- Surface drift and routing failures as issues
- Feed recurring maintenance workflows from that comparison

### 4. Reachability and Certificate Follow-Through

- Add upstream reachability validation after route changes
- Expand certificate status from placeholder messaging into operational data
- Define how Admin API changes remain durable across restarts

---

## Files Changed

| File | Change |
| --- | --- |
| `docs/INDEX.md` | Pointed session navigation at a sessions index |
| `docs/README.md` | Reflected the new sessions index in the doc tree |
| `docs/dev/CHANGELOG.md` | Added March 25 shipped-history summary for recurring ops and Caddy routing baseline |
| `docs/dev/FEATURES.md` | Marked recurring ops baseline and SSH-backed route management as shipped foundation |
| `docs/dev/ROADMAP.md` | Moved the Caddy client baseline into completed work and clarified the remaining routing gap |
| `docs/plans/INDEX.md` | Updated plan status text and session-history reference |
| `docs/plans/caddy-client.md` | Updated current reality to match the shipped client and tool wiring |
| `docs/plans/routing-caddy.md` | Updated current reality to reflect the shipped routing baseline |
| `docs/analysis/pillars-audit-2026-03-19.md` | Realigned the audit with the recurring-ops and Caddy baseline |
| `docs/sessions/INDEX.md` | New sessions navigation file |

---

## Verification

- `docs/scripts/ralph-doc-check.sh`
- `rg -n "does not exist yet|AI tools exist but are stubs|Build Caddy Admin API client" docs/analysis/pillars-audit-2026-03-19.md docs/dev/ROADMAP.md docs/plans/INDEX.md`
