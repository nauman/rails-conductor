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

- Caddy Admin API client
- Desired vs actual route model
- Domain to upstream mapping for Docker and native apps
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
2. Build a `CaddyClient` that can read, write, validate, and snapshot route state.
3. Persist desired route state in the database and reconcile it with live Caddy config.
4. Verify reachability after route changes and record failures.
5. Support rollback when route changes fail validation.

## Dependencies

- `docs/plans/domains-dns.md`
- `docs/plans/cloudflare.md`
- runtime backend routing targets from Docker and native deploy flows

## Milestones

1. Model domains, upstreams, ports, and route ownership.
2. Implement `CaddyClient` with route CRUD and validation.
3. Add route reconciliation job for desired vs actual state.
4. Add certificate status tracking and route drift detection.
5. Add UI for domain to upstream mapping and route health.

## Risks

- Config conflicts if multiple writers touch Caddy.
- Route drift if manual edits happen outside Conductor.
- Route rollback may be harder than route creation if changes are partial.

## Open Questions

- Should Conductor be the sole writer to Caddy config?
- Should rollback use full config snapshots or route-level patches?
- How should global Caddy vs per-host Caddy be represented?
