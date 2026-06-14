# SC-002: Publish a Route for an App

## User Story (Raw)

> "I deployed an app on a server. Now I just want to point a domain at it and have it live with HTTPS, without editing Caddy config by hand."

---

## Actors

| Actor | Description |
|-------|-------------|
| **Indie Developer** | Wants a deployed app reachable on a domain. |
| **App** | A running app listening on a Unix socket or local port. |
| **Server** | The host running the app and Caddy (Admin API on :2019). |
| **Caddy** | Reverse proxy + Let's Encrypt. Conductor manages its routes. |
| **Conductor** | Adds/removes the route via the SSH-backed Caddy client. |

---

## Goals

1. **One-step publish** — point a domain at an app without hand-editing Caddy.
2. **Automatic TLS** — certificate is issued and renewed by Caddy.
3. **Reversible** — a published route can be removed cleanly.

---

## Scenario Flow

### Scenario 2.1: Publish a domain

**Preconditions:**
- App is deployed and listening on a known socket/port.
- Server has Caddy running with the Admin API reachable.

**Flow:**
1. Developer opens the app and chooses "Add domain".
2. Developer enters the domain (e.g. `example.com`) and the upstream (socket/port).
3. Conductor calls the Caddy client (`add_domain` tool / `CaddyClient#upsert_route`).
4. Caddy creates a managed route tagged `conductor-route-<domain>` and begins TLS issuance.
5. UI shows the route as published, with status `created`.

**Acceptance Criteria:**
- [ ] Route appears in Caddy tagged as Conductor-managed (not manual routes).
- [ ] HTTPS works once the certificate is issued.
- [ ] Re-publishing the same domain updates rather than duplicates the route.

### Scenario 2.2: Unpublish a domain

**Flow:**
1. Developer chooses "Remove domain" on the app.
2. Conductor calls `remove_domain` / `CaddyClient#remove_route(domain)`.
3. The managed route is removed; only Conductor-managed routes are eligible.

**Acceptance Criteria:**
- [ ] Manual (non-Conductor) routes are never touched.
- [ ] Removing an absent domain is a safe no-op with a clear message.

---

## Data Model Implications

```
App (1) ──→ (N) Route   # currently derived from Caddy; persistence is a planned gap
                ├── domain
                ├── upstream (socket | host:port)
                ├── route_id (conductor-route-<domain>)
                └── status (created | removed)
```

## Technical Notes

- Built on `CaddyClient` and `AddDomainTool` / `RemoveDomainTool`.
- Routes are identified by the `conductor-route-<domain>` `@id` so Conductor only manages its own.
- See `docs/plans/caddy-client.md` and `docs/plans/routing-caddy.md`.

## Open Questions

1. Where do routes persist in Conductor's DB (vs. read live from Caddy)?
2. How is certificate issuance status surfaced back to the UI?

## Priority

**High** — this is the core "make it reachable" loop for native hosting.
