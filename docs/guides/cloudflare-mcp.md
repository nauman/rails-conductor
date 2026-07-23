---
title: Connect Cloudflare (multi-account) + attach Cloudflare's MCP
description: Connect one or more Cloudflare accounts to Conductor and give an agent Cloudflare's MCP over the same fleet.
order: 7
---

# Cloudflare + Conductor

Conductor connects to **one or more Cloudflare accounts** and lets an agent attach
**Cloudflare's own MCP** — so the same agent that drives your fleet can also drive
Cloudflare (DNS, zone settings, analytics).

## 1. Connect an account (multi-account)

1. Create a **Cloudflare API token** (My Profile → API Tokens). For managing
   DNS + SSL, grant *Zone → DNS → Edit* and *Zone → Zone Settings → Edit* (and
   *Zone → Zone → Read*). Token can be account- or zone-scoped.
2. In Conductor, **Credentials → Add Credential**, provider **Cloudflare**, paste the
   token as the API key, name it after the account (e.g. `intellecta`, `inventlist`).
3. Click **Verify** — Conductor checks the token and caches the account's **zones**,
   so it knows which account owns which domain.

Repeat for each account. We run two (INTELLECTA + InventList); both connect side by
side, and each domain resolves to whichever account owns its zone.

## 2. Attach Cloudflare's MCP

Cloudflare hosts **remote MCP servers** — you connect a client to them; Conductor
doesn't self-host them. The most useful is the **API MCP server**, which wraps the
entire Cloudflare API (2,500+ endpoints incl. DNS records / proxied status and
`update_zone_setting` for SSL mode) behind two tools, `search()` and `execute()`.

Each connected account's card shows a ready-to-run attach command using **that
account's token as the bearer**:

```
claude mcp add --transport http cloudflare-<account> https://api.mcp.cloudflare.com/mcp \
  --header "Authorization: Bearer <token>"
```

**OAuth alternative** (no token in the command): add the server URL and let your MCP
client redirect you to Cloudflare to authorize interactively —
`claude mcp add --transport http cloudflare https://api.mcp.cloudflare.com/mcp`.
Cloudflare also hosts product-specific servers (docs, observability, radar, DNS
analytics, audit logs…) at `https://<service>.mcp.cloudflare.com/mcp`.

Once attached, your agent has **Conductor's tools and Cloudflare's** over the same
fleet — e.g. inspect a zone, flip a record to proxied, or read DNS analytics inline.

## Direct actions vs MCP

- **Conductor's own buttons** (e.g. the upcoming "Put behind Cloudflare") call the
  Cloudflare API **directly** with the stored token — deterministic, no agent needed.
- **Cloudflare's MCP** is for **agent-driven, ad-hoc** work (debugging, analytics,
  one-off changes). They share the same per-account token you connected.

## Security

The attach command embeds a **live token** — treat it like a password. Conductor
stores the token encrypted and the Credentials page is operator-only. Prefer a
scoped token (only the permissions above) over a global key.

## References

- [Cloudflare's MCP servers](https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/)
- [Cloudflare API MCP server](https://github.com/cloudflare/mcp)
