# Domains & DNS Plan

## Goal
Automate domain and subdomain management via Cloudflare and sync with routing.

## Scope
- Add/remove DNS records for app environments.
- Track domain → app mapping.
- Health checks for DNS correctness.

## Non-goals
- Multi-provider DNS support in v1.

## Milestones
1. Cloudflare credentials storage.
2. DNS record creation/update UI.
3. DNS validation and alerts.

## Dependencies
- Caddy routing layer for upstream mapping.

## Risks
- DNS propagation delays.

## Open Questions
- Should we support wildcard cert flow by default?
