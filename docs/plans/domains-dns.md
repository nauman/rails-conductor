# Domains & DNS Plan

## Pillar
Routing and edge

## Status
Partial

## Current Reality

- Domain fields exist, but domain lifecycle is not operationalized.
- DNS record automation is missing.
- Domain correctness checks and alerts do not exist.

## Goal

Automate domain and subdomain management, keep DNS aligned with routing, and make “domain to live app” a visible workflow.

## Scope

- Domain to app mapping
- DNS record creation, update, and deletion
- DNS correctness checks and propagation verification
- Domain connection state in the UI
- Alignment between DNS targets and Caddy route state

## Non-goals

- Multi-provider DNS support in v1
- Domain transfer workflows in the first pass
- Full registrar marketplace from day one

## Core Workflows

1. Connect a domain or subdomain to an app.
2. Create or update DNS records needed to point traffic correctly.
3. Verify DNS correctness before or after route publication.
4. Surface propagation delays or misconfigurations as issues.

## Requirements

1. Track domain ownership, connection status, DNS target, and verification state.
2. Support record creation and updates through Cloudflare-backed flows first.
3. Add DNS validation checks such as expected target, resolution status, and propagation state.
4. Show domain setup as a multi-step workflow, not just a field on the app model.
5. Keep DNS state aligned with routing state and surface mismatches.

## Dependencies

- `docs/plans/cloudflare.md`
- `docs/plans/routing-caddy.md`

## Milestones

1. Define domain model and connection state.
2. Add DNS record create/update/delete flows.
3. Add DNS validation and propagation checks.
4. Link domain state to Caddy route status and issue reporting.

## Risks

- DNS propagation delays may look like failures if not modeled correctly.
- Operators may expect domain purchase and DNS management to be the same flow.
- Wildcard and apex-domain behavior can diverge operationally.

## Open Questions

- Should wildcard cert flow be supported by default?
- Should domain buying live here or in provider automation flows only?
- What is the minimum acceptable propagation check before marking an app live?
