# Cloudflare Integration Plan

## Goal
Integrate Cloudflare for DNS automation and R2 credentials management.

## Scope
- Store Cloudflare API tokens per workspace.
- Manage DNS records for domains/subdomains.
- Link R2 bucket configuration to backup workflows.

## Non-goals
- WAF or advanced Cloudflare security settings in v1.

## Milestones
1. Cloudflare credential storage + validation.
2. DNS record management UI.
3. R2 bucket listing and selection in backups.

## Dependencies
- Domain model and routing sync.
- Backup pipeline for R2 usage.

## Risks
- Token permissions too broad or too narrow.

## Open Questions
- Token per zone vs account-wide token?
