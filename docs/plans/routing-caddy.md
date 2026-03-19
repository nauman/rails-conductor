# Routing (Caddy) Plan

## Pillar
Routing and edge

## Status
Partial

## Current Reality

- Native deploys can run, but route wiring does not exist.
- Domain add/remove tools are stubs.
- Caddy Admin API integration is missing.
- SSL state is mostly metadata, not an operational system.

## Goal

Make Conductor the source of truth for how traffic reaches apps: domains, Caddy routes, certificates, and reachability.

## Scope

- Product-level route lifecycle for managed apps
- Desired vs actual route model
- Domain to upstream mapping for Docker and native apps
- Deploy-to-route publication rules
- Cross-server move semantics
- Route validation, rollback, and drift detection
- Certificate visibility and status checks

## Non-goals

- Multi-region global edge routing in v1
- Supporting arbitrary reverse proxies in the first pass
- Replacing CDN or WAF features

## Core Workflows

1. Add a domain to an app and publish a route.
2. Change an upstream after deploy and verify traffic health.
3. Move an app between servers without leaving stale routes behind.
4. Detect route drift or certificate problems and surface them as issues.

## Requirements

1. Store Caddy API endpoint, auth details, and route ownership metadata.
2. Persist desired route state in the database and reconcile it with live Caddy config through `docs/plans/caddy-client.md`.
3. Model upstream target type explicitly for Docker port targets and native socket targets.
4. Define when route publication happens in the deploy lifecycle and when it does not.
5. Verify reachability after route changes and record failures.
6. Support rollback when route changes fail validation.
7. Treat Conductor as the only supported writer of managed route state in v1.

## Dependencies

- `docs/plans/caddy-client.md`
- `docs/plans/domains-dns.md`
- `docs/plans/cloudflare.md`
- runtime backend routing targets from Docker and native deploy flows

## Milestones

1. Model domains, upstreams, upstream types, ports/sockets, and route ownership.
2. Define deploy-flow hooks for first publish, republish, and move operations.
3. Integrate product routing workflows with `CaddyClient`.
4. Add route reconciliation job for desired vs actual state.
5. Add certificate status tracking and route drift detection.
6. Add UI for domain to upstream mapping and route health.

## Upstream Model

This plan must treat Docker and native apps differently at the routing layer.

### Docker upstream

- expected target form: local host plus mapped port
- example shape: `127.0.0.1:<port>`

### Native upstream

- expected target form: Unix socket for Puma
- example shape: `/tmp/puma-<app>.sock`

This means route state needs an explicit upstream type rather than a single generic string with hidden assumptions.

## Deploy Lifecycle Integration

Routing is not a side concern. It must attach to deploy success explicitly.

### First publish

1. deploy or bootstrap the app successfully
2. resolve desired upstream target
3. publish the managed route
4. validate upstream reachability
5. mark route as live only after validation

### Redeploy on same host

1. deploy new version
2. keep the same domain and ownership mapping
3. update or validate the current upstream target if port/socket state changed
4. revalidate reachability

### Route publication trigger

This plan assumes route publication should happen as a distinct step after successful deploy health checks, not inline as an untracked side effect. Whether that lands as a follow-up job or an explicit post-deploy service call is an implementation detail, but the route publish step must be visible in the deployment lifecycle.

## Cross-Server Move Workflow

Moving an app between servers is one of the highest-risk routing operations and should be treated as an ordered workflow.

### Required order

1. deploy app to the new server
2. publish route on the new server's Caddy
3. validate new-server upstream reachability
4. only after validation, remove or deactivate the old route
5. update the app's primary server association and route state

### Failure behavior

- if validation on the new server fails, keep the old route in place
- do not leave the system claiming the move is complete when traffic still depends on the old host
- rollback should prefer preserving known-good traffic rather than completing state changes optimistically

Atomicity is not assumed in v1. Ordered safety is more important than pretending the move is a single atomic transaction.

## Caddy Deployment Model

Per-host Caddy is the v1 model.

Why:

- it matches current provisioning scripts
- it matches the SSH-first control model
- it aligns with the existing `server.caddy_port` schema
- global edge routing is already a non-goal

This plan therefore assumes route state is server-scoped in v1 unless an explicit later edge layer is introduced.

## Config Persistence Mode

Conductor-managed routing depends on Caddy Admin API changes surviving restart.

Therefore, v1 should assume Conductor-managed servers use a Caddy JSON-config-compatible operating mode rather than a workflow where a static Caddyfile overwrites Admin API state on restart.

If Caddyfile-based boot remains in use, the implementation must define how Admin API mutations become durable. That durability question is part of routing correctness, not an optional polish item.

## Reachability Validation

Requirement 5 should not depend on external DNS propagation in the first pass.

### v1 validation method

- validate the local upstream from the server side
- prefer local `curl` or equivalent checks against the resolved upstream target
- treat external DNS-dependent checks as a later layer, not the first publish gate

This keeps route validation focused on "can Caddy reach the app target" before introducing "can the public internet resolve and reach the domain."

## UI Surface

The first routing UI does not need to be large, but it must be explicit.

Recommended v1 surface:

- route state on the app show page
- server-scoped route visibility on the server show page
- route health indicators in operational views

Minimum fields to show:

- domain
- upstream type
- upstream target
- validation status
- last published at
- last validated at
- drift/conflict state if present

## Risks

- Config conflicts if multiple writers touch Caddy.
- Route drift if manual edits happen outside Conductor.
- Route rollback may be harder than route creation if changes are partial.
- Caddy config persistence can be lost if the runtime mode and Admin API assumptions do not match.

## Decisions

### Sole writer to managed routes

Yes for v1. Conductor is the only supported writer for managed route state. Manual edits are unsupported but should be detectable as drift.

### Rollback approach

Use the snapshot-based approach defined in `caddy-client.md` for v1.

### Caddy topology

Use per-host Caddy in v1. Global/shared edge routing remains a later architecture decision outside the first implementation.
