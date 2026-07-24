# 03 — Cloudflare Origin CA certificates: end-to-end trust for Full (Strict)

Status: **Spec — for review** (2026-07-24). Follow-up to
`01-cloudflare-integration.md`. Raised while putting calm.page behind Cloudflare:
`put_behind_cloudflare` flips DNS to proxied and sets the zone SSL mode, but it
never provisions an **origin certificate**. This is fine for **Full** mode (which
doesn't validate the origin cert) but blocks **Full (Strict)**, the mode that
actually guarantees CF↔origin trust.

## Motivation / scope

Today `CloudflareClient` exposes `verify`, `zones`, `dns_record`, `set_proxied`,
`set_ssl_mode` — no certificate issuance. So a domain put behind Cloudflare rides
on **Full** (encrypted CF↔origin, but the origin cert is *not* validated). To move
to **Full (Strict)** — the recommended posture — the origin must present a cert CF
trusts. Two ways to get one:

1. The origin already runs a public CA cert (Let's Encrypt via Caddy/kamal-proxy)
   — Full (Strict) then works with **no Conductor change**. This is calm.page's
   situation, which is why Origin CA is **not** a blocker there.
2. The origin has no public cert (private/internal origin, IP-only origin, or an
   operator who doesn't want to run ACME on the box) — needs a **Cloudflare Origin
   CA cert**: a long-lived (up to 15y) cert Cloudflare's edge trusts, installed on
   the origin. This is the gap Conductor could close.

**Non-goal:** replacing Let's Encrypt where it already works. Origin CA is for
origins that can't/don't run public ACME, or fleets that want CF-issued origin
trust managed centrally.

## Background: Cloudflare Origin CA API

- `POST /certificates` (Origin CA) issues a cert for hostnames in a zone. Auth is
  **not** the normal API token — it uses either the **Origin CA Key** (a special
  `X-Auth-User-Service-Key` header) or an API token with the **SSL and
  Certificates: Edit** permission (token-based Origin CA issuance).
- Input: a CSR (or let CF generate the key), the hostnames, `request_type`
  (`origin-rsa` / `origin-ecc`), and `requested_validity` (days).
- Output: the signed certificate (PEM). The private key is either your CSR's key
  or returned by CF if CF generated it.
- The cert is only trusted **by Cloudflare's edge**, not browsers — correct,
  because browsers see CF's edge cert, and CF↔origin is the leg being secured.

## Design

### A. Client — add issuance to CloudflareClient

```
CloudflareClient#issue_origin_cert(hostnames:, csr:, validity_days: 5475, type: "origin-rsa")
  → POST /certificates  (Origin CA)  → { certificate, expires_on, id }
```

Auth: prefer a token with **SSL and Certificates: Edit** (same multi-account
`Credential` model); fall back to a stored **Origin CA Key** if present. Add a
capability check so we fail clearly when the connected token lacks the scope
(mirrors the Zone-Settings gap we already hit on SSL mode).

### B. Key/CSR handling

- Conductor generates the keypair + CSR locally (so the private key never leaves
  Conductor), sends only the CSR. Store the private key encrypted (like
  `Credential#api_secret` / deploy keys).
- Never log the key; redact in MCP audit (same `\A...key\z` rules).

### C. Install on the origin

The cert+key must land on the origin's edge terminator:
- **Caddy** (Conductor's standard edge, ADR 0002): write the cert/key and point a
  site block's `tls <cert> <key>` at them, reload via the Admin API.
- **kamal-proxy**: materialize the pair and reference it in the proxy TLS config.
- Idempotent + renewable: a job re-issues before `expires_on` and reloads.

### D. Wire into the cutover

Extend `CloudflareCutover.put_behind!` with an optional `ssl_mode: "strict"`
path: issue (or reuse) an Origin CA cert, install it, verify the origin serves it,
then set the zone SSL mode to **Full (Strict)**. Default stays **Full** (today's
zero-config behavior) — Strict is opt-in per site/fleet.

### E. MCP + UI

- MCP: a `conductor_domain` action (e.g. `secure_origin`) or an option on
  `put_behind_cloudflare` (`ssl_mode: "strict"`) that runs the issue+install flow.
- UI: on the site panel, a "Harden to Full (Strict)" affordance shown only when
  the domain is already proxied.

## Security

- Origin CA private key generated and stored by Conductor, encrypted, never
  logged, never in MCP payloads/audit.
- Token scope check up front (SSL and Certificates: Edit) with a legible error,
  not a deep failure.
- Cross-tenant: issuance uses the org's own connected Cloudflare credential only.

## Test plan (TDD)

- `CloudflareClient#issue_origin_cert`: happy path (stubbed HTTP), scope-missing
  error, validity/type params.
- CSR/key generation: key stays local; CSR carries the right hostnames.
- Cutover Strict path: issues → installs → verifies origin → sets Full (Strict);
  aborts (no SSL-mode change) if install/verify fails.
- Redaction: private key never appears in logs/audit.

## Open questions (for the reviewer)

1. **Token vs Origin CA Key.** Prefer the token path (SSL and Certificates: Edit)
   for consistency with the existing multi-account `Credential`, and only support
   the legacy Origin CA Key if a user has one? Proposed: token-first.
2. **Who terminates TLS on the origin?** Caddy (ADR 0002 direction) vs current
   kamal-proxy — the install step differs. Proposed: implement Caddy first, since
   that's the standard edge, and treat kamal-proxy as a secondary adapter.
3. **Renewal cadence.** Origin CA certs can be very long-lived (up to 15y). Do we
   still run a renewal job, or issue long and revisit? Proposed: issue ~1y and run
   the same renewal job pattern as ACME, so rotation is exercised.
4. **Is this even wanted before Full (Strict) demand exists?** calm.page and other
   LE-fronted origins don't need it. Gate build on a real origin that lacks a
   public cert, or build proactively for the fleet-hardening story?

---

### For the reviewer (Codex)

- Confirm the **Origin CA auth** model (token scope `SSL and Certificates: Edit`
  vs Origin CA Key) and which Conductor should implement first.
- Sanity-check that **Full (not Strict)** is genuinely sufficient for LE-fronted
  origins (so this is an enhancement, not a calm.page blocker).
- Weigh **build-now vs build-on-demand** given no current origin needs it.
