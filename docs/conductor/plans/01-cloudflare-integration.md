# 01 — Cloudflare integration (multi-account): connections, MCP attach, "Put behind Cloudflare"

Status: **Spec** (2026-07-23). Motivated by the calm.page slowness diagnosis — a
far origin + no CDN — and the need to drive Cloudflare from Conductor + agents.

## Goals

1. **Connect multiple Cloudflare accounts** (our case: two — INTELLECTA + InventList).
2. **Attach Cloudflare's MCP** so an agent driving Conductor can also drive Cloudflare.
3. **"Put behind Cloudflare"** — per-site *and* fleet-wide — proxy a domain + set SSL
   mode via the Cloudflare API, then watch the site monitor improve.

## Background: how Cloudflare's MCP works

Cloudflare hosts **remote MCP servers** at `https://<service>.mcp.cloudflare.com/mcp`
(docs, observability, radar, DNS-analytics, audit-logs, …). Auth is **OAuth**
(interactive) **or an API token as a bearer**. The **official API MCP server**
(`github.com/cloudflare/mcp`) wraps the *entire* Cloudflare API — 2,500+ endpoints
incl. DNS records (proxied) and `update_zone_setting` (SSL mode) — behind just two
tools: `search()` and `execute()`. These are **client-side connections**; Conductor
does not self-host them. So "attach" = give the agent's MCP client the server URL +
a token.

## Design

### A. Cloudflare connections (multi-account) — foundation
- Reuse the existing `Credential` model (`provider: "cloudflare"`, encrypted
  `api_key` = API token). **Multiple records = multiple accounts**, each with a name.
- Add: `account_id` + a **Verify** action that calls `GET /user/tokens/verify` and
  lists the account's **zones** (cached), so Conductor knows which domains each
  account owns.
- Domain → zone → account resolution: for any app domain, find the zone (across all
  connected accounts) whose name is a suffix of the domain.

### B. Attach Cloudflare MCP
- Per connected account, a **"Connect Cloudflare MCP"** panel that generates the
  client attach config, using that account's token as the bearer, e.g.
  `claude mcp add --transport http cloudflare https://api.mcp.cloudflare.com/mcp \
     --header "Authorization: Bearer <token>"` (and the OAuth alternative).
- A `/docs/cloudflare-mcp` guide documenting the servers, OAuth vs token, and scope.
- Result: an agent gets Conductor's tools **and** Cloudflare's `search`/`execute`
  over the same fleet — ad-hoc DNS/zone/analytics ops alongside Conductor's actions.

### C. "Put behind Cloudflare" — per-site + fleet
- A small `CloudflareClient` (direct API, per account token). Actions:
  - **proxy on**: set the domain's `A`/`CNAME` DNS record `proxied: true`.
  - **SSL mode**: `PATCH /zones/:id/settings/ssl` → `full` (origin keeps TLS) or
    `flexible` (origin HTTP-only, for the `ssl:false` catch-all model).
- **Per-app**: a "Put behind Cloudflare" button on the app page (resolves account/zone
  automatically, defaults SSL=Full = zero-downtime with the current origin TLS).
- **Fleet-wide**: a bulk action ("Put all sites behind Cloudflare") that iterates
  monitorable apps and applies it, skipping already-proxied ones.
- Deterministic (direct API), not agent-mediated — a reliable button. The site
  monitor's sparkline shows the before/after.

## Why direct API for the buttons *and* MCP for agents
The fleet buttons must be deterministic → direct `CloudflareClient`. The MCP attach is
for **agent-driven, ad-hoc** work (debugging, analytics, one-off zone changes) — the
two complement each other and share the same stored token per account.

## Phasing
- **P1 — Connections + MCP attach** (A + B). Small: leans on `Credential`; mostly UI +
  a verify call + an attach-config generator + a docs guide.
- **P2 — Put behind Cloudflare, per-app** (C, single). `CloudflareClient` + the button
  + monitor before/after.
- **P3 — Fleet-wide + SaaS custom domains** (C, bulk; Cloudflare-for-SaaS for
  `*.domain` + customer domains — the `ssl:false` catch-all end-state).

## Open questions
- Store the CF token only in `Credential` (encrypted), or also mirror to localvault?
- OAuth flow vs token-only for the MCP attach (token-only is simpler, no callback).
- Zone-list caching TTL + refresh trigger.
