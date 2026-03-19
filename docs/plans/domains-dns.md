# Domains & DNS Plan

## Pillar
Routing and edge

## Status
Partial

## Current Reality

- Domain fields exist, but domain lifecycle is not operationalized.
- Domain state currently lives mostly in `app.domain`, which is too thin for a real workflow.
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

1. Track domain ownership, connection status, DNS target, and verification state in first-class domain data, not only an app string field.
2. Support record creation and updates through Cloudflare-backed flows first.
3. Add DNS validation checks such as expected target, resolution status, and propagation state.
4. Show domain setup as a multi-step workflow, not just a field on the app model.
5. Keep DNS state aligned with routing state and surface mismatches.

## Dependencies

- `docs/plans/cloudflare.md`
- `docs/plans/routing-caddy.md`

## Milestones

1. Define Domain model and connection state.
2. Define DNS record creation rules for apex and subdomain cases.
3. Add DNS record create/update/delete flows.
4. Add DNS validation and propagation checks.
5. Link domain state to Caddy route status and issue reporting.

## Domain Model

This plan should treat domains as first-class records rather than stretching `App.domain` into a workflow engine.

### Recommended v1 approach

Create a dedicated Domain model or equivalent table.

Why:

- one app may need more than one domain
- domain connection state is richer than a single string
- domain and route state need to be aligned but are not the same concept

### Minimum domain fields

- domain
- app reference
- server reference where relevant
- DNS provider
- DNS record type
- DNS target
- connection status
- verification method
- verified at
- last check at
- last error

## Relationship to Route State

Domain state and route state are related but distinct.

### Domain state answers

- is DNS pointing where we expect?
- has the domain been connected and verified?

### Route state answers

- has Caddy published and validated the route?
- can traffic be served to the resolved upstream?

### Handoff model

1. domain is connected to an app
2. DNS record is created or updated
3. DNS verification succeeds
4. route publication becomes eligible
5. route validation completes
6. app is considered reachable

This means Domain and Route must stay aligned, but neither should replace the other.

## DNS Record Creation Rules

The first pass should not leave record choice ambiguous.

### v1 default flow

1. operator connects a domain to an app
2. Conductor resolves the app's target server and expected DNS target
3. Conductor creates the appropriate DNS record through Cloudflare
4. Conductor verifies DNS resolution from its own network
5. successful verification allows route publication to proceed

### Record type rules

#### Apex domains

- use `A` record in v1
- treat apex handling as explicit because apex cannot rely on a normal RFC-style CNAME path

#### Subdomains

- may use `CNAME` or `A` based on target design
- v1 should prefer the simplest target model that matches deployment assumptions

#### IPv6

- AAAA support can come later unless the host model already requires it

The record type should be inferred by Conductor based on domain shape and target style rather than delegated entirely to the operator in the first pass.

## Propagation Verification

Verification should be simple and local in the first implementation.

### Recommended v1 method

- resolve DNS from Conductor's own network
- compare the answer to the expected target
- treat one successful matching resolution as enough to proceed

This avoids waiting for full global propagation while still proving the domain is beginning to point correctly.

Background rechecks can strengthen confidence later.

## Existing `app.domain` Field Migration

The existing string field should not disappear abruptly.

### v1 migration approach

- keep `app.domain` temporarily as a convenience accessor or primary-domain shortcut
- migrate existing domain strings into Domain records
- move new lifecycle behavior onto Domain records first
- transition helpers and views gradually rather than through one destructive rewrite

This lets the product keep working while the richer domain workflow is introduced.

## Apex and Wildcard Handling

### Apex domains

Treat apex domains explicitly in record selection and validation.

### Wildcards

Do not support wildcard flow by default in v1.

Wildcard support introduces DNS-challenge and certificate complexity that does not belong in the first domain workflow.

## Deploy Interaction

This plan should acknowledge deploy interaction even if the first implementation keeps it simple.

Recommended stance:

- connecting a domain does not automatically trigger a deploy
- once a deployed app has a verified domain, route publication can proceed
- later UX may offer "deploy and connect domain" as one guided workflow, but domain connection should remain a valid standalone action

## Risks

- DNS propagation delays may look like failures if not modeled correctly.
- Operators may expect domain purchase and DNS management to be the same flow.
- Wildcard and apex-domain behavior can diverge operationally.

## Decisions

### Wildcard support

No wildcard flow by default in v1.

### Domain purchase

Do not include domain purchase in v1. Assume the operator already owns the domain and wants to connect it.

### Minimum propagation threshold

One successful DNS resolution from Conductor's network that matches the expected target is enough to proceed to route publication in v1.
