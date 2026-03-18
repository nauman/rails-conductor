# SC-001: Kamal App Monitoring Dashboard

## User Story (Raw)

> "I want an app which can monitor my Kamal 2 apps and can visually restart and show kamal tail logs. I really want to see a holistic view of how many sites we have."

---

## Actors

| Actor | Description |
|-------|-------------|
| **Indie Developer** | Primary user. Runs 2-10 Kamal-deployed apps across 1-3 servers. Wants visibility without SSH-ing into each box. |
| **Server** | A VPS (Hetzner/DO) running Docker containers deployed via Kamal 2. |
| **Kamal App** | A containerized app managed by Kamal. Has a name, image, and deployment config. |
| **Conductor** | This system. Orchestrates monitoring, restarts, and log viewing. |

---

## Goals

1. **Holistic Dashboard** - See all Kamal apps across all servers at a glance
2. **App Status Visibility** - Know which apps are running, stopped, or unhealthy
3. **One-Click Restart** - Restart any app without SSH
4. **Live Log Tailing** - View `kamal app logs` output in the browser

---

## Scenario Flow

### Scenario 1.1: View All Sites (Holistic Dashboard)

**Preconditions:**
- Developer has registered 1+ servers in Conductor
- Servers have Kamal-deployed apps

**Flow:**
1. Developer opens Conductor dashboard
2. System displays summary cards:
   - Total servers: X
   - Total apps: Y
   - Healthy: Z | Unhealthy: W
3. Developer sees a list/grid of all apps with:
   - App name
   - Server it's on
   - Status (running/stopped/error)
   - Last deploy time

**Acceptance Criteria:**
- [ ] Dashboard loads in < 2 seconds
- [ ] Status refreshes automatically (polling or websocket)
- [ ] Can filter by server or status

---

### Scenario 1.2: Restart an App

**Preconditions:**
- App is registered and visible in dashboard

**Flow:**
1. Developer clicks "Restart" button on an app card
2. System shows confirmation modal
3. Developer confirms
4. System runs `kamal app boot` (or appropriate restart command) via SSH
5. UI shows "Restarting..." spinner
6. On success: status updates to "Running", toast notification
7. On failure: status shows "Error", error message displayed

**Acceptance Criteria:**
- [ ] Restart completes within 60 seconds for typical app
- [ ] User sees real-time feedback during restart
- [ ] Errors are surfaced clearly (not silent failures)

---

### Scenario 1.3: View Live Logs

**Preconditions:**
- App is registered and running

**Flow:**
1. Developer clicks "Logs" button on an app
2. System opens log viewer panel/modal
3. System streams output of `kamal app logs -f` via SSH
4. Logs appear in real-time (like a terminal)
5. Developer can:
   - Scroll through log history
   - Search/filter logs (nice-to-have)
   - Pause/resume stream
6. Developer closes panel, stream disconnects

**Acceptance Criteria:**
- [ ] Logs stream in real-time (< 1 second delay)
- [ ] Log viewer handles high-volume output without freezing
- [ ] Connection cleans up properly on close

---

## Data Model Implications

```
Server (1) ──→ (N) App
                   ├── name
                   ├── kamal_service_name
                   ├── status (running | stopped | error | unknown)
                   ├── last_deployed_at
                   └── container_id (optional, for direct docker commands)
```

---

## Technical Notes

### Kamal 2 Commands Reference

```bash
# List apps/services
kamal app containers

# Restart an app
kamal app boot

# Tail logs
kamal app logs -f

# Check app status
kamal app details
```

### Implementation Options

| Approach | Pros | Cons |
|----------|------|------|
| SSH + Kamal CLI | Native, uses existing Kamal setup | Requires Kamal installed on server |
| SSH + Docker directly | No Kamal dependency for runtime | Loses Kamal abstractions |
| Docker API over SSH tunnel | Programmatic, rich data | More complex setup |

**Recommendation:** Start with SSH + Kamal CLI for simplicity. Kamal is already installed on deployment servers.

---

## Open Questions

1. How do we discover Kamal apps on a server? (Parse `kamal.yml`? Scan docker containers with labels?)
2. Should we support non-Kamal Docker apps too?
3. Log retention - stream only or store recent logs?

---

## Priority

**High** - This is the core MVP use case for Conductor.
