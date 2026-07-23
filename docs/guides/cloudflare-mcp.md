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

Cloudflare hosts **remote MCP servers** (you connect a client to them; Conductor
doesn't self-host them). Auth is **OAuth — it triggers automatically on first tool
use**, so there's no token in the attach command. The main one wraps the Cloudflare
API behind `search()` / `execute()` (DNS records / proxied status, `update_zone_setting`
for SSL mode, and more).

**Servers** (per Cloudflare's agent-setup):

| Name | URL |
| --- | --- |
| `cloudflare` (main API) | `https://mcp.cloudflare.com/mcp` |
| `cloudflare-docs` (public, no auth) | `https://docs.mcp.cloudflare.com/mcp` |
| `cloudflare-bindings` | `https://bindings.mcp.cloudflare.com/mcp` |
| `cloudflare-builds` | `https://builds.mcp.cloudflare.com/mcp` |
| `cloudflare-observability` | `https://observability.mcp.cloudflare.com/mcp` |

**Claude Code — use the plugin** (recommended):

```
claude plugin marketplace add cloudflare/skills
claude plugin install cloudflare@cloudflare
# then run /reload-plugins inside Claude
```

**Other MCP clients — add the server** (OAuth on first use). Name it per account so
you can authorize each account in its own OAuth flow — the Credentials page shows a
ready-to-copy command per connected account:

```
claude mcp add --transport http cloudflare-<account> https://mcp.cloudflare.com/mcp
```

Once attached, your agent has **Conductor's tools and Cloudflare's** over the same
fleet — inspect a zone, flip a record to proxied, read DNS analytics, inline.

> For headless/CI automation with a token instead of OAuth, see the self-runnable
> **Code Mode** server at `github.com/cloudflare/mcp`.

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
