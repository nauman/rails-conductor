# SC-005: Connect a Domain (DNS + Route)

## User Story (Raw)

> "I bought a domain. I want Conductor to point its DNS at my server and publish the route, so the app is live on that domain end to end."

---

## Actors

| Actor | Description |
|-------|-------------|
| **Indie Developer** | Wants a domain fully connected to an app. |
| **DNS Provider** | Cloudflare, managed via API. |
| **Caddy** | Terminates TLS and routes the domain to the app. |
| **Conductor** | Creates the DNS record and the Caddy route together. |

---

## Goals

1. **One flow, both halves** — create the DNS record *and* the Caddy route.
2. **Verify resolution** — confirm DNS points at the server before/after publishing.
3. **Clean teardown** — disconnecting removes both the record and the route.

---

## Scenario Flow

### Scenario 5.1: Connect a domain

**Preconditions:**
- Cloudflare credentials are stored in Conductor.
- The target app is deployed on a server with a public IP.

**Flow:**
1. Developer enters the domain and selects the target app/server.
2. Conductor creates an A/AAAA (or CNAME) record at Cloudflare pointing to the server.
3. Conductor publishes the Caddy route (see SC-002) for the domain.
4. Conductor checks that the domain resolves to the server and that HTTPS comes up.

**Acceptance Criteria:**
- [ ] DNS record and Caddy route are created as one logical action.
- [ ] Resolution/propagation status is shown, not assumed instant.
- [ ] Partial failures (DNS ok, route failed, or vice versa) are reported, not hidden.

### Scenario 5.2: Disconnect a domain

**Flow:**
1. Developer disconnects the domain.
2. Conductor removes the Caddy route, then deletes the DNS record.

---

## Data Model Implications

```
Domain
 ├── name
 ├── app / server (association)
 ├── dns_record_id (provider reference)
 ├── route_id (conductor-route-<domain>)
 └── status (connecting | live | error)
```

## Technical Notes

- DNS half depends on Cloudflare API work — see `docs/plans/cloudflare.md` and `docs/plans/domains-dns.md`.
- Route half reuses SC-002 (`CaddyClient` / `AddDomainTool`).
- This scenario is the composition of DNS automation + routing into one user-facing action.

## Open Questions

1. Proxied vs. DNS-only records at Cloudflare?
2. How long to wait/poll for propagation before declaring "live"?

## Priority

**High** — this is the headline "domain to live app" experience.
