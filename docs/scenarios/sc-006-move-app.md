# SC-006: Move an App to Another Server

## User Story (Raw)

> "I want to move an app from one server to another — deploy it on the new box, switch the domain over, and tear down the old route — without downtime or hand-editing two Caddy configs."

---

## Actors

| Actor | Description |
|-------|-------------|
| **Indie Developer** | Consolidating or rebalancing apps across servers. |
| **App** | The app being relocated. |
| **Source / Target Server** | The old and new hosts, each running Caddy. |
| **Conductor** | Orchestrates deploy, route cutover, and teardown across both hosts. |

---

## Goals

1. **Deploy on the target** — get the app running on the new server first.
2. **Cut over routing** — move the domain from source to target Caddy.
3. **Tear down cleanly** — remove the old route (and optionally the old app) after cutover.

---

## Scenario Flow

### Scenario 6.1: Move an app

**Preconditions:**
- Both servers are registered and reachable.
- The app's deploy config and data plan (DB/backups) are known.

**Flow:**
1. Developer selects the app and chooses "Move to server" → target server.
2. Conductor sets up and deploys the app on the target (scripts + deploy over SSH).
3. Conductor verifies the target app is healthy.
4. Conductor publishes the domain route on the target Caddy (SC-002) and removes it from the source Caddy.
5. Conductor marks the app as now running on the target; the old instance can be stopped/removed.

**Acceptance Criteria:**
- [ ] Cutover only happens after the target app is confirmed healthy.
- [ ] Route exists on exactly one server at the end (no split routing).
- [ ] A failure mid-move leaves a clear, recoverable state (source still serving).

---

## Data Model Implications

```
App
 ├── server_id            # changes on a successful move
 ├── previous_server_id   # for rollback/teardown
 └── status (moving | running | error)
```

## Technical Notes

- Composes existing deploy + Caddy route tooling across two hosts; the new part is the **orchestration and ordering** (deploy → verify → cutover → teardown).
- Multi-host orchestration is a known gap — see `docs/analysis/pillars-audit-2026-03-19.md` and the routing plans.
- Data migration (DB/backups) may be a prerequisite step depending on the app.

## Open Questions

1. Does "move" include database migration, or only the app runtime + routing?
2. How is downtime minimized — pre-warm target before cutover?

## Priority

**Medium** — high-value once routing and multi-host basics are solid.
