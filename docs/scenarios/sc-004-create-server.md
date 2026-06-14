# SC-004: Create and Bootstrap a Server

## User Story (Raw)

> "I want to click 'new server', have Conductor create the VM at my provider, and bring it from a bare box to something I can deploy to — without a checklist of manual SSH commands."

---

## Actors

| Actor | Description |
|-------|-------------|
| **Indie Developer** | Wants a new, deploy-ready host. |
| **Provider** | Hetzner (or similar) where the VM is created via API. |
| **Server** | The new VM, registered in Conductor. |
| **Conductor** | Creates the VM, then runs bootstrap provisioning over SSH. |

---

## Goals

1. **Create from the panel** — provision a VM via the provider API.
2. **Bootstrap automatically** — deploy user, Caddy, PostgreSQL, Redis, firewall, Ruby.
3. **End in a known-ready state** — the server is registered, reachable, and marked ready.

---

## Scenario Flow

### Scenario 4.1: Create a server

**Preconditions:**
- Provider API credentials are stored in Conductor.
- An SSH key is available to register with the new VM.

**Flow:**
1. Developer chooses "New server", picks provider, region, and size.
2. Conductor calls the provider API to create the VM and registers the SSH key.
3. Conductor records the server with status `provisioning`.

### Scenario 4.2: Bootstrap the server

**Flow:**
1. Once the VM is reachable, Conductor runs the bootstrap scripts over SSH:
   `server-provision` → `ruby-install`.
2. Output streams live via ActionCable.
3. On success, the server is marked `online` / ready for app setup.

**Acceptance Criteria:**
- [ ] VM creation errors (quota, auth) are surfaced clearly.
- [ ] Bootstrap is idempotent — re-running does not break a half-provisioned host.
- [ ] Final state clearly distinguishes "created" from "ready to deploy".

---

## Data Model Implications

```
Server
 ├── provider, region, size
 ├── ip_address, ssh_user
 ├── ssh_key (association)
 └── status (provisioning | online | error)
```

## Technical Notes

- Provider API integration (Hetzner) does not exist yet — see `docs/plans/provisioning-hetzner.md` and `docs/plans/server-bootstrap.md`.
- Bootstrap reuses existing provisioning scripts and SSH streaming; only VM creation + the orchestration are new.

## Open Questions

1. How is VM readiness detected (SSH reachable, cloud-init done)?
2. Which providers beyond Hetzner are in scope first?

## Priority

**Medium-High** — unlocks the full "zero to deployed" loop.
