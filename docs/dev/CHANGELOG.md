# Changelog

Lightweight shipped-history summary. For implementation detail and verification, see `docs/sessions/`.

## 2026-03-12

- Fixed schema mismatches in `servers` and `deployments`
- Added `Deployment` server association support
- Replaced deploy-page polling with ActionCable log streaming
- Added deployment seed data for realistic local state

Source: `docs/sessions/2026-03-12-production-readiness.md`

## 2026-03-25

- Added recurring ops baseline scheduling for metrics refresh, container sync, and scheduled backup dispatch
- Added SSH-backed `CaddyClient` service with route fetch/upsert/remove, config snapshots, and basic validation
- Wired add/remove domain tools to the real Caddy client and added test coverage

Source: `docs/sessions/2026-03-28-routing-baseline-and-doc-realignment.md`

## 2026-07-12

- Separated desired app state, observed runtime state, and monitoring confidence on Overview
- Replaced stopped-app noise with deduplicated, actionable runtime incidents
- Fixed lazy Solid Queue Turbo Frames and added full job-health drill-down
- Added labelled Sync, Logs, and Restart controls with guarded restart confirmation
- Contained navigation and fleet rows at mobile, tablet, and desktop widths

Source: `docs/sessions/2026-07-12-operational-dashboard-health.md`

## 2026-07-27

- Added an OAuth 2.1 authorization server for the MCP endpoint: discovery (RFC 8414 + 9728), dynamic client registration (RFC 7591), authorization code + PKCE(S256), refresh tokens
- Bound OAuth tokens to one organization (picker for multi-org users) and to this MCP resource (RFC 8707); membership re-checked on every call
- Required an explicit consent screen at `/oauth/authorize` (a GET never authorizes) so open client registration can't yield drive-by grants
- Stored OAuth token secrets as digests, failed write access closed (needs `mcp` scope + operator), and added connected-client revocation on the Tokens page
- Accepted OAuth tokens at `/mcp` alongside static tokens, and answered unauthenticated calls with a `WWW-Authenticate` challenge
- Documented browser sign-in for Codex / claude.ai / `mcp-remote` in the MCP guide

Source: `docs/conductor/plans/06-mcp-oauth-connect.md`
