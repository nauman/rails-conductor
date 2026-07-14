# Duplication Audit — 2026-07-14

A straightforward single-pass audit of "duplicate code / too many ways to do the
same thing." Evidence is grep-backed; counts are approximate but real. Ordered
by impact. The MCP concern extraction shipped this session
(`McpAuthentication` / `McpToolInvocation`) is the model pattern to copy.

## High impact

### 1. Core operations implemented 3× (HTML vs API vs MCP)
Server registration and app deploy each exist in three parallel places:
- `app/controllers/servers_controller.rb`, `app/controllers/api/v1/servers_controller.rb`, `app/tools/register_server_tool.rb`
- `app/controllers/apps_controller.rb`, `app/controllers/api/v1/apps_controller.rb`, `app/tools/deploy_app_tool.rb`

Each path builds the record / dispatches deploy its own way, so a fix or rule
(validation, org assignment, deploy method dispatch) has to be made in three
spots and drifts.
**Consolidate to:** a plain domain service / model method (e.g.
`Server.register(...)`, `App#deploy!`) that all three thin layers call. The
controllers/tool become adapters (parse input → call → render).

### 2. Tenant scoping copy-pasted across ~18 controllers
Every controller re-does `current_organization.<assoc>` for index and
`current_organization.<assoc>.find(params[:id])` in ~15 `set_*` before_actions.
No shared mechanism; a new nullable-org / leakage rule can't be enforced once.
**Consolidate to:** an `OrganizationScoped` controller concern providing
`scoped(:servers)` / a generic `set_resource`, so tenant enforcement lives once.

### 3. Authorization scattered inline (~13 sites, no policy layer)
`require_admin!`, `require_owner!`, `current_organization.owner?(current_user)`
sprinkled through controllers. Only Conversations has a permission class
(`app/permissions/`). Rules aren't discoverable or testable in one place.
**Consolidate to:** extend the existing permission pattern (or a light policy
object) to servers/apps/members rather than ad-hoc `if` checks.

## Medium impact

### 4. Three ways to render a status/badge
- `status_badge` helper (8 files)
- `rui_badge(...)` component (12 files)
- raw inline Tailwind pills (`rounded-pill` / `rounded-full`, ~24 files)

Same visual concept, three implementations; colors/sizes drift.
**Consolidate to:** `rui_badge` as the one component; fold `status_badge`'s
status→color map into it, migrate inline pills opportunistically.

### 5. Empty-state + card markup duplicated
~7 near-identical dashed-border empty states and ~44 `rounded-large … shadow-soft`
card shells, hand-written per view.
**Consolidate to:** `rui_empty_state(...)` and a `rui_card` wrapper; adopt on
touch, don't big-bang.

## Quick wins (low risk, high value)
1. `OrganizationScoped` concern for index + `set_*` finders (kills #2, shrinks every controller).
2. Fold `status_badge` into `rui_badge`; delete the helper once callers move (#4).
3. Extract `Server.register` / `App#deploy!` and point the API + MCP tool at it first (they're the thinnest), then the HTML controller (#1).

## Acceptable — leave alone (don't over-engineer)
- Thin per-controller `*_params` methods: Rails idiom, keep local.
- Small view differences that only *look* similar but carry different actions.
- The two MCP surfaces (REST + JSON-RPC) — already share concerns; the split is intentional (curl vs native transport).
