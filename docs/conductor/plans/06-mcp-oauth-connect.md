# 06 — MCP OAuth connect (browser sign-in for agents)

Status: **SHIPPED (2026-07-27)** — Conductor is an OAuth 2.1 authorization server
for its own MCP endpoint, so any MCP client (Codex, claude.ai, Cursor, the
`mcp-remote` bridge) connects by signing in through the browser instead of the
user minting and pasting a bearer token. Static `ApiToken`s are untouched.

Reference implementation: the same slice in a sibling app (doorkeeper + RFC
8414/9728 discovery + RFC 7591 registration + RFC 8707 audience binding), which
was live-smoked against Codex CLI. Conductor adds **organization binding**, which
that app didn't need.

## Why

Before this, `/mcp` accepted exactly one credential: a bearer token minted at
`/mcp_tokens` and hand-pasted into an agent's config. That has three costs:

1. **Friction** — every new client is a copy-paste ritual, and the token ends up
   in a config file (often committed) and in shell history.
2. **No discovery** — the `401` carried no `WWW-Authenticate` challenge and there
   was no metadata document, so a client had no way to *offer* to connect. Hosted
   connector UIs (claude.ai, the OpenAI Apps directory) can't onboard a
   server they can't discover auth for.
3. **Long-lived secrets** — a static token doesn't expire, doesn't rotate, and
   isn't per-client, so revocation is coarse.

OAuth fixes all three: the user never sees a secret, tokens are short-lived and
refreshable, and each client holds its own revocable grant.

## What shipped

| Piece | Where |
|---|---|
| `doorkeeper ~> 5.8` (authorize / token / revoke), authorization-code + PKCE(S256) only, refresh tokens, 2h access tokens | `config/initializers/doorkeeper.rb` |
| Discovery: `/.well-known/oauth-authorization-server` (RFC 8414), `/.well-known/oauth-protected-resource` (+ `/mcp` suffixed form) (RFC 9728) | `app/controllers/oauth/metadata_controller.rb` |
| Dynamic client registration `POST /oauth/register` (RFC 7591) → public PKCE client, rate-limited 10/h/IP | `app/controllers/oauth/registrations_controller.rb`, `config/initializers/rack_attack.rb` |
| Authorize gate: passwordless sign-in (resumes the authorize URL after the magic link), then a consent screen that binds the organization | `app/controllers/oauth_base_controller.rb`, `app/views/oauth/*` |
| Token secrets stored as digests (`hash_token_secrets`), matching `ApiToken` | `config/initializers/doorkeeper.rb` |
| Connected-clients list + revoke on the Tokens page | `app/controllers/oauth_connections_controller.rb`, `app/views/mcp_tokens/index.html.erb` |
| `/mcp` accepts OAuth tokens (org- and audience-checked) and challenges unauthenticated callers with `WWW-Authenticate` | `app/controllers/concerns/mcp_authentication.rb` |
| Tables + `resource` / `organization_id` on grants and tokens | `db/migrate/20260727000001_create_doorkeeper_tables.rb` |
| 19 integration tests — discovery, registration, authorize, full code→token exchange, and every refusal | `test/integration/mcp_oauth_connect_test.rb` |

Scopes are **`mcp`** (full/deploy) and **`mcp_read`** (read-only), mirroring
`ApiToken`'s `deploy` / `read`. Write access is **fail-closed**: it needs the `mcp`
scope *and* `OperatorPolicy.operator?(user, org)`, the same rule
`McpTokensController` applies when issuing a token — so a plain member can't get a
more privileged request state through OAuth than through the token page. A token
carrying neither MCP scope authenticates as nothing at all.

## Consent is mandatory — do not "simplify" it away

The GET at `/oauth/authorize` **never** authorizes. It renders a consent screen
naming the client, the redirect target, the access level, and the organization;
only the CSRF-protected POST that form submits can mint a grant.

This is not ceremony. Registration is open (RFC 7591), so *anybody* can be a
client. If a GET could authorize, an attacker would register a redirect URI they
control and get a signed-in user's browser to hand them a code with no
interaction at all — authorization-endpoint CSRF. PKCE is no defence, because the
attacker is the client holding the verifier. `skip_authorization { true }` is safe
*only* because our own consent step runs first; auto-approving without it would
reopen the hole.

## The Conductor-specific part: organization binding

Conductor is multi-tenant. `Current.org_scoped` confines an MCP caller to one org
— even an admin — and `ApiToken` forbids org-less write tokens at the model level.
An OAuth token therefore has to carry an org too, or it would be the one unscoped
writer in the system.

How it works:

1. The consent form carries `organization_id` (a hidden field for a single-org
   user, radio buttons for a multi-org one) along with every other authorize param
   — `client_id`, PKCE challenge, `state`, `resource` — resubmitted verbatim.
2. Membership is verified before the param is honoured; asking for someone
   else's org renders `403` and issues no grant.
3. `custom_access_token_attributes [:resource, :organization_id]` carries both
   from authorize request → grant → access token, **and across refreshes**
   (doorkeeper copies custom attributes from the previous token).
4. Membership is re-checked on **every** MCP call. A token must not outlive the
   membership it was minted under — the same rule org-bound `ApiToken`s follow.

Membership is *not* re-checked when a refresh token is redeemed, only when the
resulting access token is used at `/mcp` — so a removed-then-re-added user's old
client resumes working without re-authorizing. Revoking the connection is the
answer; see "deliberately not done".

## What `/mcp` refuses

- A token with **no bound `resource`**, or one bound to a different resource
  (RFC 8707). MCP clients are expected to send the resource indicator; Codex does
  via `--oauth-resource`. This is the confused-deputy defence: a token phished for
  another MCP server cannot be replayed here.
- A token whose **org is missing** or whose user **left the org**.
- A revoked or expired token (`accessible?`).

Unauthenticated calls now answer `401` with
`WWW-Authenticate: Bearer resource_metadata="…/.well-known/oauth-protected-resource"`,
which is what turns a dead end into a "Connect" prompt in a client.

## Client recipes

Codex (`codex-cli` 0.145+, native remote MCP):

```bash
codex mcp add conductor --url https://<host>/mcp --oauth-resource https://<host>/mcp
codex mcp login conductor      # browser: sign in, pick an org
```

`mcp-remote` works with no token in the config at all (it is itself an OAuth
client and does DCR + PKCE). Full guide: `docs/guides/mcp.md` → `/docs/mcp`.

## Notes for whoever touches this next

- **Loopback redirects.** `force_ssl_in_redirect_uri` carves out
  `localhost` / `127.0.0.1` / `::1` (RFC 8252): native clients receive the code on
  an ephemeral plain-http loopback listener. Without the carve-out, registration
  from Codex fails in production with `secured_uri`.
- **The token endpoint is not behind the app's gates.** Doorkeeper's
  `TokensController` runs on its own metal controller, so `base_controller
  "OauthBaseController"` only affects the HTML authorize endpoint — CSRF and the
  auth/onboarding gates never touch `POST /oauth/token`.
- **Registration is open** (RFC 7591 with no initial access token). It grants
  nothing by itself and is rate-limited; the boundary is the authorize step. If
  abuse ever shows up, gate it behind a signed-in user rather than a secret.

## Audit trail

An independent audit (Codex, 2026-07-27) reviewed the whole diff. Fixed in place:
the drive-by-grant hole (no interactive consent — was rated critical), plaintext
token storage, write access fail-open for plain members and unknown scopes, and
the missing revocation path. Two findings were **pre-existing** behaviour this
change only inherits, left alone deliberately:

- The legacy shared `CONDUCTOR_MCP_TOKEN` runs as the first admin with **global**
  scope and no org binding — documented as a root credential, but it does violate
  the one-user/one-org invariant the other two paths hold.
- An **org-less** `ApiToken` leaves `Current.organization` nil, so `actor_org_ids`
  falls back to *all* of the user's orgs — read-only, but not confined to one org.

Both are worth closing; both change behaviour for credentials already in use, so
they belong in their own change, not this one.

## Deliberately not done

- **Token-endpoint audience enforcement.** The `resource` is captured and checked
  at `/mcp`, but the token endpoint doesn't reject a mismatched `resource` at
  exchange time (the grant's value wins, so it doesn't widen access). `/mcp` also
  accepts a token bound to the bare origin as well as the advertised
  `<origin>/mcp` — both name this same server, and refusing the origin form would
  break clients that bind to the issuer.
- **Revoking on membership removal.** Destroying a membership stops the access
  token at `/mcp` but leaves the refresh lineage intact, so a re-added user's old
  client resumes. Revoke the connection to be sure.
- **Registry listings.** `server.json` (MCP Registry) and an OpenAI Apps SDK
  submission would make this discoverable to other people's agents, not just the
  operator's own.
