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
- R2 uploads already happen through the existing backup pipeline, but bucket/account management does not.

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

## API Reference

The first implementation should explicitly target Cloudflare's REST API rather than leaving endpoint discovery implicit.

Relevant endpoint shapes:

- `GET /zones` — list zones
- `GET /zones/:id/dns_records` — list DNS records
- `POST /zones/:id/dns_records` — create DNS record
- `PUT /zones/:id/dns_records/:id` — update DNS record
- `DELETE /zones/:id/dns_records/:id` — delete DNS record
- `GET /accounts/:id/r2/buckets` — list R2 buckets
- `POST /accounts/:id/r2/buckets` — create R2 bucket
- `GET /user/tokens/verify` — verify bearer token

## Client Strategy

This plan should assume direct HTTP calls from Conductor to Cloudflare, not SSH-mediated execution.

### Recommended v1 approach

- use a direct HTTP client from the Rails app
- use Cloudflare's REST API directly
- use the existing AWS/S3 path separately for actual R2 object upload behavior

This is preferable to introducing another tool boundary because Cloudflare is already a cloud API, not a host-local service.

## Credential Integration

The existing `Credential` model already stores provider-specific secret material. Cloudflare integration should fit that model rather than inventing a parallel credential path prematurely.

### v1 credential mapping

- store the Cloudflare bearer token in the existing credential secret field path used for provider auth
- do not require a key/secret pair conceptually for Cloudflare
- keep the client constructor and lookup path explicit so the app knows which credential is being used for DNS and R2 access

This plan should assume Conductor passes an explicit Cloudflare credential into `CloudflareClient`, not a hidden global singleton.

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
6. Keep bucket management separate from the existing backup upload path until a better end-to-end replacement exists.

## Dependencies

- `docs/plans/domains-dns.md`
- `docs/plans/backups-r2.md`
- `docs/plans/routing-caddy.md`

## Milestones

1. Add credential validation and permission checks.
2. Implement zone listing and DNS record CRUD.
3. Implement R2 bucket listing, selection, and creation flows.
4. Connect Cloudflare state into the domain setup and backup configuration UI surfaces.

## Risks

- Token permissions may be too broad or too narrow.
- Cloudflare account boundaries may complicate zone and R2 discovery.
- Partial permissions can create confusing failure states if not surfaced clearly.
- Rate limiting can make retries look like permission failures if errors are flattened.

## Existing R2 Upload Boundary

The current backup path already uploads artifacts to R2-compatible storage through the backup service.

For v1, this plan should complement that path, not replace it:

- `CloudflareClient` manages account-level discovery and bucket setup
- existing backup upload logic continues to handle the actual artifact upload path

This keeps scope realistic and avoids rewriting a working upload pipeline before Cloudflare account management exists.

## Rate Limiting and Error Handling

Cloudflare responses should not be flattened into generic provider failure.

At minimum, the client needs to distinguish:

- invalid or unauthorized token
- insufficient permission scope
- missing zone or bucket
- rate limiting
- transient network failure

### First-pass handling rules

1. treat token/permission failures as non-retryable until the credential changes
2. treat rate limiting as retryable with bounded backoff
3. surface rate-limit errors differently from permission errors in the UI
4. keep provider-health responses explicit enough for operators to understand what action is required

## Data Model Implications

Likely additions or clarifications:

- provider setup state for Cloudflare-backed workflows
- zone association for domains or app/domain records
- selected R2 bucket references for backup configuration
- explicit credential-to-zone or credential-to-account usage tracking if needed later

The plan does not require caching all Cloudflare state locally in v1, but it does require Conductor to know which credential and which zone/bucket are bound to a given workflow.

## UI Surfaces

Milestone 4 should be concrete.

Recommended first-pass UI surfaces:

- credential form or credential show page for token validation and permission summary
- domain setup flow for zone selection and DNS record management
- backup form or backup configuration view for R2 bucket selection

The plan does not require a dedicated Cloudflare console in v1.

## Decisions

### Token scope

Use an account-wide token in v1. Zone-scoped tokens are insufficient for R2 account workflows and complicate the first implementation.

### R2 scope

Start with backup buckets only in v1. That matches the current working backup pipeline and avoids overloading this provider plan with general object-storage product work.

### Automation style

Use guided manual confirmation in v1. Conductor should show what the token can access and what action is about to happen, but should not silently create or mutate provider resources without an explicit operator action.
