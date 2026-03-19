# Caddy Client Plan

## Pillar
Routing and edge

## Status
Partial

## Current Reality

- Conductor stores app domains, ports, and Caddy-related metadata.
- Native deploys and multi-app routing stop at the service boundary because no Caddy Admin API service exists.
- Domain add/remove tools are placeholders and do not reach a real Caddy instance.
- `SshConnection` supports remote command execution and streaming, but not SSH port forwarding.
- The higher-level routing plan exists, but the service boundary that makes it implementable is still missing.

## Goal

Define and build the `CaddyClient` service as the operational foundation for route publication, route inspection, certificate visibility, and route drift detection.

## Why This Plan Exists

`routing-caddy.md` explains what the routing product should do. This plan explains the lower-level service that makes that product real. Without this service definition, routing work stays at the concept level and every future route feature becomes ad hoc.

## Scope

- `CaddyClient` responsibilities and API surface
- Authentication and connectivity model for Caddy Admin API
- Read/write/validate/snapshot route operations
- Error handling and retry expectations
- Route and certificate inspection primitives
- Rollout sequence for integrating the client into Conductor

## Non-goals

- Replacing the higher-level routing plan
- Supporting every reverse proxy in the first implementation
- Designing a global edge abstraction for multiple providers in v1
- Solving all domain and DNS concerns inside this service

## Assumptions

- Caddy Admin API is enabled on a reachable port for the managed host or edge node.
- Conductor can reach Caddy either directly or through an SSH-mediated path.
- Conductor remains the intended source of truth for desired route state, even if manual edits are temporarily possible.

## Core Responsibilities

1. Read current Caddy config and isolate the parts Conductor owns.
2. Create, update, and remove app routes without corrupting unrelated config.
3. Validate route changes before Conductor treats them as live.
4. Snapshot or version route state for safe rollback.
5. Surface certificate and route-health information back to the rest of the product.

## Service Interface

The first version of `CaddyClient` should define explicit operations instead of exposing raw HTTP everywhere.

Recommended operations:

1. `fetch_config`
2. `fetch_managed_routes`
3. `upsert_route(route_definition)`
4. `remove_route(route_id_or_domain)`
5. `validate_route(route_definition)`
6. `snapshot_config`
7. `fetch_certificate_status(domain)`
8. `health_check`

## Connectivity Model

### Option 1: Direct Admin API access

Use when Conductor can reach Caddy over a trusted network path.

Pros:
- simpler implementation
- fewer moving parts

Cons:
- more network exposure
- less portable across self-hosted topologies

### Option 2: SSH-mediated access

Use when Caddy Admin API should remain host-local.

Pros:
- aligns with SSH-first Conductor model
- keeps Caddy admin surface off public networks

Cons:
- more moving pieces
- tunnel lifecycle and timeout handling need care

### Preferred first pass

Support a service design that can work with either direct HTTP or SSH-mediated access, but prioritize the SSH-first operational model in implementation decisions.

### Recommended v1 implementation path

Do not start with SSH port forwarding.

Instead:

1. use `SshConnection.execute`
2. run `curl` against `http://localhost:2019/...` on the target host
3. parse JSON responses inside Conductor

Why:

- it fits the current `SshConnection` capabilities
- it avoids building port forwarding before route publishing exists
- it keeps the Admin API host-local by default

Direct HTTP access can remain an upgrade path later if operationally justified.

## Caddy API Reference

The implementation should not infer Caddy endpoints from examples alone. The first pass should explicitly target the JSON Admin API.

Relevant endpoint shapes to anchor the client design:

- `GET /config/` — fetch full config
- `POST /config/apps/http/servers/<server>/routes` — append route
- `PUT /config/...` — update config subtree where needed
- `DELETE /config/apps/http/servers/<server>/routes/<index>` — remove route by index
- certificate-related inspection endpoints where available through Caddy's admin surface

Important note:

- route deletion by index is only safe if the current index is resolved immediately before mutation
- the client must not assume route indices are stable across separate reads and writes
- deletion should locate the current managed route by ownership marker first, then remove by the current index

The exact path strategy should be chosen once the managed server naming and route ownership model are fixed, but the client must map each high-level operation onto a concrete Caddy API call.

## Managed Route Model

The service should not treat Caddy config as an opaque blob. It should map Conductor route concepts into explicit fields.

Minimum route fields:

- route owner type
- route owner id
- domain or host
- upstream target
- upstream port or socket
- tls enabled state
- route id or stable key
- last published at
- last validated at
- last validation result

## Route Ownership Marker

Managed routes must be explicitly identifiable in Caddy config.

Recommended first-pass marker:

- include Conductor-owned metadata in the JSON route payload where possible
- include a stable ownership value tied to the managed app, such as `app_id`
- preserve a predictable Conductor marker such as `conductor: true`

The exact representation can be finalized during implementation, but the intent is:

- Conductor can find its routes again later
- drift detection has a stable ownership key
- unmanaged routes are distinguishable without guesswork

## Route Ownership Rules

1. Conductor-managed routes must be identifiable in Caddy config.
2. Manual unmanaged routes must not be silently overwritten.
3. Conductor should only mutate routes it owns unless an explicit migration/import path exists.
4. Route ownership metadata must support future drift detection.

## Route State Storage

This plan assumes route state becomes first-class rather than being hidden inside existing `App` columns alone.

Preferred first pass:

- add a dedicated route-oriented persistence layer for managed route state
- keep app-level domain fields as convenience data, not the only routing source of truth

That can be implemented as:

- a new `Route` model, or
- an equivalent route-state table with ownership, target, validation, and snapshot references

This is preferable to stuffing all route operational state into `App` because the route lifecycle is richer than a single domain string.

## Workflow 1: Publish a New Route

1. Resolve the desired domain and upstream target from app state.
2. Validate that the target host/port or socket is present in Conductor’s desired state.
3. Fetch current managed route state.
4. Build the desired route payload.
5. Apply the route change.
6. Validate Caddy accepted the change.
7. Run reachability checks against the expected domain or upstream.
8. Record publish result, timestamps, and any validation error.

For v1, the API call path should be executed through SSH-mediated `curl` against the local Admin API on the target host.

## Workflow 2: Remove a Route

1. Identify the managed route by domain or stable route id.
2. Snapshot the current config before mutation.
3. Remove the route.
4. Validate the route is gone.
5. Record removal outcome and any orphaned certificate state that needs follow-up.

## Snapshot Storage

Snapshot-before-mutation is the recommended v1 rollback strategy.

The plan should assume snapshots are stored in durable application data, not transient files only.

Minimum snapshot contents:

- host or edge identifier
- timestamp
- config blob or managed subtree blob
- change context
- actor or system initiator

Snapshot-based rollback is sufficient for v1 and simpler than designing route-level reverse patches immediately.

## Workflow 3: Detect Drift

1. Fetch desired route state from Conductor.
2. Fetch actual managed route state from Caddy.
3. Compare domain, upstream, TLS, and ownership fields.
4. Mark differences as drift records or routing issues.
5. Expose drift state to routing UI and recurring maintenance workflows.

Drift detection should be tied into recurring operations after the base client exists. It is not only an on-demand admin action.

## Workflow 4: Certificate Status Check

1. Ask Caddy for certificate or TLS state where possible.
2. Map result into Conductor certificate status fields.
3. Record expiry, renewal, error, or unknown state.
4. Surface failures to issue detection and future notification workflows.

For v1, certificate management should remain largely Caddy-owned. Conductor should focus on:

- certificate visibility
- expiry/error surfacing where available
- HTTPS reachability checks

## Failure Modes

### Connectivity failure

- Caddy endpoint unreachable
- SSH tunnel cannot be established
- authentication failure

Conductor behavior:
- do not mark route change as live
- preserve desired state
- record routing issue with retry context

### Partial publish failure

- config accepted but reachability fails
- route created but validation incomplete

Conductor behavior:
- mark route as pending validation or failed validation
- keep rollback path available

### Ownership conflict

- managed route collides with unmanaged route
- manual config edit changes a Conductor-owned route unexpectedly

Conductor behavior:
- do not silently overwrite
- surface explicit conflict state

## Retry and Safety Rules

1. Reads may retry more aggressively than writes.
2. Writes must be idempotent where possible.
3. Route mutation should happen only after Conductor can identify ownership clearly.
4. Snapshot before destructive changes.
5. Validation failure should never be treated as success.

## Integration Points

### Existing tool stubs

`add_domain_tool.rb` and `remove_domain_tool.rb` already exist as tool stubs.

This plan should treat them as downstream integration points:

- replace fake success responses
- route those tools through `CaddyClient`
- keep tool behavior aligned with the same ownership and validation model as the web UI

### Recurring ops

Once the base client exists, recurring operations should own:

- route reconciliation
- drift detection
- later certificate-status refresh

That ties this plan directly to `docs/plans/recurring-ops-schedule.md`.

## Data Model Implications

Likely additions or clarifications:

- route record or route-state table
- route publication state
- route validation state
- route ownership key
- certificate status and expiry
- last route sync timestamp
- drift indicator
- route snapshot storage

## Dependencies

- `docs/plans/routing-caddy.md`
- `docs/plans/domains-dns.md`
- `docs/plans/cloudflare.md`
- recurring ops for later drift and cert checks

## Milestones

1. Define route ownership and managed-route metadata.
2. Define `CaddyClient` interface and v1 connectivity via SSH-executed `curl`.
3. Define route-state persistence and snapshot storage.
4. Implement config fetch, route upsert, and route removal.
5. Add validation and snapshot support.
6. Rewire existing add/remove domain tools to the real client.
7. Add certificate inspection and route drift support.
8. Integrate reconciliation into recurring operations.

## Acceptance Checks

- Conductor can publish a managed route without manual Caddy edits.
- Conductor can remove a managed route safely.
- Failed route publication does not leave the system in an ambiguous “live” state.
- Managed vs unmanaged route conflicts are visible.
- Route state can be compared later for drift detection.

## Open Questions

### Connectivity model

Use SSH-executed `curl` against host-local Admin API in v1. Revisit direct HTTP later if needed.

### Route ownership marker

Use an explicit Conductor ownership marker plus stable app ownership metadata in the route JSON.

### Rollback strategy

Use snapshot-based rollback in v1. Route-level rollback can come later if snapshot restore proves too coarse.

### Certificate visibility

Let Caddy own certificate lifecycle in v1. Conductor should inspect status where possible and backstop it with HTTPS reachability checks.
