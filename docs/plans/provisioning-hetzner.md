# Provisioning (Hetzner) Plan

## Pillar
Provisioning and provider automation

## Status
Deferred

## Current Reality

- Hetzner credentials can be modeled and stored.
- No Hetzner API integration exists.
- Server creation is still manual outside Conductor.
- Bootstrap is SSH-first; there is no agent model in the current vision.

## API Reference

The first implementation should explicitly target Hetzner Cloud's REST API.

Base:

- `https://api.hetzner.cloud/v1/`

Auth:

- Bearer token in request header

Relevant endpoint shapes:

- `GET /server_types` — list server types and pricing
- `GET /locations` — list available locations
- `GET /ssh_keys` — list registered SSH keys
- `POST /ssh_keys` — register SSH key
- `POST /servers` — create server
- `GET /servers/{id}` — fetch server status and network details
- `DELETE /servers/{id}` — delete server
- `GET /servers/{id}/actions` — inspect action progress where needed

## Client Strategy

This plan should assume direct HTTP from Conductor to Hetzner's API rather than a provider-specific gem.

### Recommended v1 approach

- use a direct HTTP client from the Rails app
- call Hetzner's REST API directly
- keep the client small and explicit

This keeps the provider layer aligned with the Cloudflare plan and avoids adding a gem for a simple API surface.

## Credential Integration

Hetzner uses a single bearer token.

### v1 credential mapping

- store the Hetzner API token in the existing credential secret field path used for provider auth
- do not treat Hetzner as a key/secret provider conceptually
- pass an explicit Hetzner credential into `HetznerClient`

## Goal

Provision Hetzner servers from the control panel and take them from “new VM” to “ready for deploy” using Conductor-managed SSH bootstrap flows.

## Scope

- Hetzner API integration for create/list/delete server workflows
- Region, server type, image, and SSH key selection
- Pricing visibility during server selection
- Automatic registration of provisioned servers in Conductor
- Post-create polling until the host is reachable for bootstrap handoff

## Non-goals

- Advanced private networking, load balancers, or autoscaling in v1
- Support for every cloud provider in the first pass
- Replacing infrastructure-as-code for advanced users

## Core Workflows

1. Save a Hetzner credential and verify it.
2. Choose region, server type, image, and SSH key.
3. Create the server and wait for a reachable IP.
4. Hand the created server into the bootstrap workflow.
5. Register the server in Conductor and show provisioning state.

## Requirements

1. Build a `HetznerClient` for server types, locations, SSH keys, and server lifecycle actions.
2. Support Hetzner SSH key registration from stored keys.
3. Model provisioning state from requested to ready, with failure reasons.
4. Treat post-create polling and SSH reachability as explicit provisioning states.
5. Expose provisioning results to later domain, routing, and deploy workflows.
6. Surface price information during server type selection.
7. Draw a clear boundary between provider provisioning and bootstrap execution.

## Dependencies

- `docs/plans/ssh-keys.md`
- `docs/plans/server-bootstrap.md`
- `docs/plans/cloudflare.md`
- `docs/plans/routing-caddy.md`

## Milestones

1. Add credential validation and API client foundation.
2. Implement server type, region, and SSH key selection.
3. Implement VM creation payload and post-create polling until IP and provider readiness are available.
4. Hand off to `server-bootstrap.md` once SSH reachability is confirmed.
5. Connect provisioned hosts to deploy and routing flows.

## Server Creation Payload

The first implementation should make the create-server request shape explicit.

Minimum fields:

- server name
- server type
- location
- image
- registered SSH key ids

### Recommended defaults

- image: vanilla Ubuntu 24.04 LTS
- SSH keys: selected and pre-registered with Hetzner before server creation

This matches the current SSH-first bootstrap model and avoids inventing image maintenance work too early.

## Post-Create Polling

Server creation is asynchronous from the operator's perspective and should not be treated as a synchronous page action.

### v1 execution model

- create server as background work
- poll for provider-side readiness and assigned public IP
- then test SSH reachability
- then hand off to bootstrap

### Required checks

1. provider reports the server exists
2. public IPv4 is present
3. server is not in an immediate error state
4. SSH becomes reachable within a bounded timeout

The plan should assume bounded polling with timeout and explicit state transitions rather than an endless wait loop.

## Boundary With Server Bootstrap

This plan should stop at:

- credential validation
- server selection
- server creation
- IP readiness
- SSH reachability

`server-bootstrap.md` should own:

- script chain execution
- profile-specific package installation
- post-bootstrap verification
- host ready state

That boundary avoids duplicating the same operational sequence in two plans.

## Pricing Visibility

Hetzner server type selection should include visible pricing information in v1.

For one-click provisioning, users need to see what they are about to buy. Server type selection without cost visibility is incomplete.

## Deletion and Cleanup

Deletion is not the first provisioning milestone, but it cannot be ignored conceptually.

Deleting a Hetzner server has cross-pillar implications:

- routing may need cleanup
- backups may remain and should not be silently destroyed
- server records likely need lifecycle state rather than blind hard delete
- attached apps may need migration or explicit orphaned state

This plan should therefore treat provider-side deletion as a coordinated lifecycle action, not just `DELETE /servers/{id}`.

## Error Handling Expectations

Hetzner failures should not be flattened into generic provisioning failure.

At minimum, the client should distinguish:

- invalid token
- insufficient token permission
- rate limiting
- transient API outage
- create succeeded but readiness failed
- create succeeded but server entered provider error state

### First-pass handling rules

1. invalid token and permission issues are non-retryable until credential changes
2. transient provider failures may retry with bounded backoff
3. server-created-but-unreachable must be a distinct failure state
4. provisioning UI should show whether failure happened before or after server creation

## Risks

- Provider API rate limits or outages can stall setup flows.
- Bootstrap failures may leave half-configured hosts behind.
- SSH reachability timing can vary based on image and region.
- Provider-side success can still lead to unusable hosts if readiness checks are weak.

## Decisions

### First-boot method

Use SSH-driven bootstrap in v1. That matches the current script system and avoids adding provider-specific cloud-init complexity before the core flow works.

### Base image

Use vanilla Ubuntu 24.04 LTS in v1.

### Postgres and Redis installation

Install by selected stack/profile, not by default for every server. The bootstrap plan should decide that based on the host profile rather than forcing every Hetzner host into the same shape.
