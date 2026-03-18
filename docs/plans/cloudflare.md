# Cloudflare Integration Plan

## Pillar
Provisioning and provider automation

## Status
Partial

## Current Reality

- Cloudflare credentials can be stored securely.
- No Cloudflare API client exists.
- DNS CRUD and R2 account workflows are not implemented.
- Validation of saved credentials does not happen.

## Goal

Integrate Cloudflare as a first-class provider for DNS automation and R2-backed storage workflows.

## Scope

- Cloudflare API token storage and validation
- Zone discovery and selection
- DNS record CRUD for app domains and subdomains
- R2 bucket discovery, creation, and binding into backup/storage flows
- Shared provider health and permission checks

## Non-goals

- WAF, CDN, rules engine, or advanced Cloudflare security features in v1
- Multi-provider DNS abstraction in the first pass
- Full object-storage lifecycle for every app use case on day one

## Core Workflows

1. Save a Cloudflare credential and verify it works.
2. Select a zone and manage DNS records for an app.
3. Create or connect an R2 bucket for backups.
4. Surface missing permissions or invalid credentials before a setup flow fails downstream.

## Requirements

1. Build a `CloudflareClient` for zones, DNS records, and R2 account operations needed by Conductor.
2. Validate Cloudflare credentials at save time or first use with clear error states.
3. Distinguish zone-scoped operations from account-scoped operations in the UI and data model.
4. Expose Cloudflare setup state to domain, routing, and backup flows.
5. Record provider errors as actionable issues rather than hidden setup failures.

## Dependencies

- `docs/plans/domains-dns.md`
- `docs/plans/backups-r2.md`
- `docs/plans/routing-caddy.md`

## Milestones

1. Add credential validation and permission checks.
2. Implement zone listing and DNS record CRUD.
3. Implement R2 bucket listing, selection, and creation flows.
4. Connect Cloudflare state into domain and backup UIs.

## Risks

- Token permissions may be too broad or too narrow.
- Cloudflare account boundaries may complicate zone and R2 discovery.
- Partial permissions can create confusing failure states if not surfaced clearly.

## Open Questions

- Token per zone vs account-wide token?
- Should R2 support start with backup buckets only or include app storage buckets too?
- How much of Cloudflare setup should be automatic vs guided manual confirmation?
