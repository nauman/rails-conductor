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
   token as the API key, and name it after the Cloudflare account it belongs to.
3. Click **Verify** — Conductor checks the token and caches the account's **zones**,
   so it knows which account owns which domain.

Repeat for each account. Several can be connected side by
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

## After you proxy a domain: restore the real client IP

The moment a domain is proxied, every request reaches your origin **from a
Cloudflare edge**. Rails builds `request.remote_ip` from `X-Forwarded-For` but
only skips proxies it trusts, and it trusts private ranges by default —
Cloudflare's are public. So `remote_ip` becomes the edge, for every visitor.

Nothing breaks loudly, which is why this is usually found months later. What
quietly stops working is anything that counts per IP: rate limiting, abuse
controls, geo lookups, analytics, per-IP connection accounting. The symptom is
unmistakable once you look: a handful of addresses account for every request in
the log, and no visitor's real address appears even once.

Fix it in the app, once:

```ruby
# config/environments/production.rb
#
# Cloudflare's published ranges — https://www.cloudflare.com/ips-v4 and /ips-v6.
# They change rarely; re-check when you next touch this file.
CLOUDFLARE_RANGES = %w[
  173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
  141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
  197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
  104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
  2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
  2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
].map { |cidr| IPAddr.new(cidr) }

# Keep the defaults — dropping them makes Rails distrust your own proxy.
config.action_dispatch.trusted_proxies =
  ActionDispatch::RemoteIp::TRUSTED_PROXIES + CLOUDFLARE_RANGES
```

**Do not read `CF-Connecting-IP` unconditionally.** It is a header, so anything
that can reach your origin directly can set it. It is only trustworthy when the
peer is genuinely Cloudflare — which is exactly what `trusted_proxies` above
establishes, and why that is the safer route.

Verify it worked by looking at your logs: client addresses should be your
visitors, not `162.158.*` / `172.64–172.71.*`.

## Security

The attach command embeds a **live token** — treat it like a password. Conductor
stores the token encrypted and the Credentials page is operator-only. Prefer a
scoped token (only the permissions above) over a global key.

## References

- [Cloudflare's MCP servers](https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/)
- [Cloudflare API MCP server](https://github.com/cloudflare/mcp)
