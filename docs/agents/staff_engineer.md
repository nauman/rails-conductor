# Staff Engineer Guide (Conductor)

The engineering brief for anyone — human or agent — writing code in this repo. It captures how we build: senior-level, vanilla-Rails, Hotwire-first judgment, with tests leading the way.

## Workflow

1. **Tests first (TDD).** Write the failing test that describes the behavior, watch it fail, then write the minimum code to make it pass. Don't write code and backfill tests.
2. **Run the suite before and after.** `bin/rails test` must be green. A change isn't done until there's a test that proves the behavior.
3. **Small, reversible changes.** Prefer well-named, testable steps over cleverness. Infrastructure changes should make later product work simpler, not more magical.

## Defaults

### Product-shaped routing
Routes mirror user intent and domain boundaries. If one endpoint serves marketing, app shell, and data API at once, split it.

### First-class domain concepts
Prefer records, concerns, and explicit nouns over boolean drift and method soup. Split a model once it starts holding unrelated responsibilities.

### Shallow controllers
Load context → authorize → call a clear domain API → render the next state. Keep business logic in models/POROs, not controllers.

### Server-rendered composition
- ERB partials for structure.
- Turbo Frames/Streams for async slices.
- Stimulus for interaction only — small, local, behavioral. Avoid long JS controllers that render markup the server could own.

### Explicit scope and identity
When the product supports multiple orgs/servers/apps, pass identity explicitly through routes and mutations. Hidden fallback behavior should shrink as the product matures.

### Shared interaction primitives
Dropdowns, drawers, modals, toasts, async panels converge on shared patterns. Repeated patches are a signal to build a primitive, not to keep duplicating.

## Conductor specifics

- **Vanilla Rails 8** with Turbo, Importmaps, Tailwind, Solid Queue/Cache/Cable. No SPA framework.
- **Activity-based authorization.** Permission lives in `*Permission` classes consulted via `User#can?(action, record)` (see `app/models/user.rb` and `ConversationPermission`). Add a permission class per resource rather than scattering role checks in controllers/views. This is the foundation the org/role model extends.
- **UI helpers are local.** `rui_badge/button/button_to/link/alert` and `f.rui_button` are defined in `app/helpers/rui_components_helper.rb` (plain Tailwind) — not a gem. Extend them there.
- **Execution is SSH-based.** Conductor acts on servers over SSH (no agent installed on hosts); long operations stream via ActionCable.
- **Deploy is Kamal.** See `config/deploy.yml`. Secrets come from the environment / `.kamal/secrets` (never commit real secrets).

## Review checklist

- Is there a test that proves the behavior, written first?
- Does the route express the screen or workflow clearly?
- Are domain boundaries explicit and understandable?
- Is the UI mostly server-rendered, with Stimulus doing interaction (not layout)?
- Is authorization expressed through a permission class, with scope/identity explicit?
- Are repeated UX fixes collapsed into shared primitives?
- Is the change small and reversible?
