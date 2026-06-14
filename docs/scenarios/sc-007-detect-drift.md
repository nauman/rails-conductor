# SC-007: Detect Drift Across the Fleet

## User Story (Raw)

> "I want Conductor to tell me when reality has drifted from what it expects — a route that vanished from Caddy, a service that's down, a cert about to expire, a backup that silently stopped — before a user hits the problem."

---

## Actors

| Actor | Description |
|-------|-------------|
| **Indie Developer** | Wants early warning, not surprises. |
| **Server / App / Route / Backup** | The resources whose actual state is checked. |
| **Conductor** | Periodically reconciles expected vs. actual state and raises issues. |

---

## Goals

1. **Reconcile expected vs. actual** — compare Conductor's model against live state on the hosts.
2. **Surface drift as issues** — show what diverged, where, and since when.
3. **Alert on the important ones** — notify on drift that risks downtime or data loss.

---

## Scenario Flow

### Scenario 7.1: Recurring drift check

**Preconditions:**
- Servers are registered and reachable.
- Recurring ops jobs are scheduled.

**Flow:**
1. A scheduled job runs across the fleet.
2. For each server, Conductor checks:
   - Caddy routes present vs. expected (`conductor-route-*`).
   - Managed services/containers running vs. expected.
   - Certificate expiry windows.
   - Backup freshness (last successful backup within SLA).
3. Divergences are recorded as fleet issues with type, resource, and first-seen time.
4. Issues above a severity threshold trigger alerts (email today; webhooks/Slack planned).

**Acceptance Criteria:**
- [ ] Drift checks run on schedule without manual triggering.
- [ ] Each issue names the resource and what diverged (expected vs. actual).
- [ ] Resolved drift clears its issue automatically on the next clean check.

---

## Data Model Implications

```
Issue
 ├── kind (route_missing | service_down | cert_expiring | backup_stale | ...)
 ├── resource (server/app/route/backup ref)
 ├── severity
 ├── first_seen_at
 └── resolved_at
```

## Technical Notes

- Builds on the recurring-ops baseline (metrics refresh, container sync) and dashboard issue detection — see `docs/plans/recurring-ops-schedule.md`.
- Drift detection, cert monitoring, and non-email notifications are open gaps in `docs/analysis/pillars-audit-2026-03-19.md`.
- Route reconciliation overlaps with SC-002's "persist routes" question — you can't detect a missing route without a recorded expectation.

## Open Questions

1. Where does "expected state" live for routes/services (DB records vs. declared config)?
2. What severities trigger alerts, and how is alert fatigue avoided?

## Priority

**Medium-High** — this is the pillar-6 payoff that makes the fleet trustworthy over time.
