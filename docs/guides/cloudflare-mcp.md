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

Cloudflare hosts **~15 capability-scoped remote MCP servers** (you connect a client to
them; Conductor doesn't self-host them). Auth is **OAuth — it triggers automatically on
first tool use**, so there's no token in the attach command.

Conductor attaches **only the read/diagnose servers** — never the broad
`mcp.cloudflare.com/mcp` aggregate, and never the mutating ones (`bindings` = Workers
deploy/delete, DNS-edit, cache-purge). This is the same least-privilege stance as the
[privileged-ops sudo wrappers](privileged-ops): agents get a **non-destructive** surface
for diagnosis, while the few config changes Conductor actually needs — turning the proxy
on, setting SSL mode — flow through Conductor's own narrow, audited `CloudflareClient`,
**not** through MCP. So a connected agent can read a zone's analytics but structurally
**cannot** delete a zone, redeploy a Worker, or purge cache.

**Servers Conductor attaches** (all read-only):

| Name | URL | Purpose |
| --- | --- | --- |
| `docs` (public, no auth) | `https://docs.mcp.cloudflare.com/mcp` | Cloudflare docs |
| `dns-analytics` | `https://dns-analytics.mcp.cloudflare.com/mcp` | zone/DNS analytics |
| `observability` | `https://observability.mcp.cloudflare.com/mcp` | logs / metrics |
| `graphql` | `https://graphql.mcp.cloudflare.com/mcp` | analytics GraphQL |
| `radar` | `https://radar.mcp.cloudflare.com/mcp` | internet insights |

**Deliberately omitted:** `mcp.cloudflare.com/mcp` (broad aggregate), `bindings`
(Workers), and any DNS-edit / cache-purge server — those can mutate config, so they're
not part of the attach set. Mutations are Conductor's job, done via vetted actions.

**Claude Code — use the plugin** (recommended):

```
claude plugin marketplace add cloudflare/skills
claude plugin install cloudflare@cloudflare
# then run /reload-plugins inside Claude
```

**Other MCP clients — add the servers** (OAuth on first use). Each is named per account
+ capability so you can authorize each account in its own OAuth flow — the Credentials
page shows the ready-to-copy commands (one per read-only server) per connected account:

```
claude mcp add --transport http cf-<account>-docs          https://docs.mcp.cloudflare.com/mcp
claude mcp add --transport http cf-<account>-dns-analytics https://dns-analytics.mcp.cloudflare.com/mcp
claude mcp add --transport http cf-<account>-observability https://observability.mcp.cloudflare.com/mcp
claude mcp add --transport http cf-<account>-graphql       https://graphql.mcp.cloudflare.com/mcp
claude mcp add --transport http cf-<account>-radar         https://radar.mcp.cloudflare.com/mcp
```

Once attached, your agent has **Conductor's tools and Cloudflare's read surface** over
the same fleet — inspect a zone, read DNS analytics, diagnose slowness inline. To
*change* anything (proxy on/off, SSL mode), use Conductor's own action below.

> For headless/CI automation with a token instead of OAuth, see the self-runnable
> **Code Mode** server at `github.com/cloudflare/mcp`.

## Direct actions vs MCP

- **Conductor's own buttons** ("Put behind Cloudflare", per-site or fleet) call the
  Cloudflare API **directly** through `CloudflareClient` with the stored token — a
  narrow, audited surface: only `set_proxied` + `set_ssl_mode`. Deterministic, logged,
  no agent needed. **This is the only path that mutates Cloudflare config.**
- **Cloudflare's MCP** (the read-only servers above) is for **agent-driven, ad-hoc
  diagnosis** — analytics, logs, docs. It cannot change config; that's by design.

## Security

The attach command embeds a **live token** — treat it like a password. Conductor
stores the token encrypted and the Credentials page is operator-only. Prefer a
scoped token (only the permissions above) over a global key.

## References

- [Cloudflare's MCP servers](https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/)
- [Cloudflare API MCP server](https://github.com/cloudflare/mcp)
