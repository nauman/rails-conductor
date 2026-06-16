# Multi-Tenancy & Accounts Plan

## Pillar
Cross-cutting (Tenancy & Accounts)

## Status
Partial — org models, scoping, and switching shipped; onboarding, invitations, admin, and billing pending.

## Current Reality

- `Organization` + `Membership` models exist; a user can belong to many orgs with a `member`/`owner` role.
- Every user has at least one org (`User#ensure_personal_organization!`); the first user bootstraps as the platform admin.
- `Current.organization` is set per request; a nav switcher changes the active org.
- `Server`, `App`, `Credential`, `Backup`, `SshKey` carry `organization_id` and are loaded/created strictly via `current_organization`. The dashboard is scoped too. Cross-org access returns 404.
- Signup is invite-only (no auto-account creation).
- Gap: the JSON API (`/api/v1/*`) is not yet org-scoped.

## Goal

Make Conductor a safe multi-tenant product: every tenant (organization) sees only its own infrastructure, owners can invite teammates, a platform webmaster can administer the whole instance, and a hosted tier can charge for usage — without leaking data across tenants.

## Scope

- Organizations as the unit of tenancy; users join via memberships with roles.
- Per-org isolation across all resources, the dashboard, and the JSON API.
- Smooth first-run onboarding (see `docs/plans/onboarding.md`).
- Invitations: owner invites by email → magic link → joins the org.
- Platform admin (webmaster) section: manage users/orgs across the instance.
- Paid hosted tier: plans, subscriptions, and usage limits for the cloud version.

## Non-goals

- Per-resource ACLs finer than org + role (kept activity-based via `*Permission` classes).
- SSO/SAML in the first pass.
- Metered/usage-based billing beyond simple plan tiers initially.

## Slices

1. **Models** — `Organization`, `Membership`, roles. ✅ shipped
2. **Auth wiring** — personal org, `Current.organization`, switcher. ✅ shipped
3. **Resource scoping** — `organization_id` + scoped controllers + dashboard. ✅ shipped
4. **Onboarding** — first-run org naming + empty-state guidance. ← active (`docs/plans/onboarding.md`)
5. **Invitations** — invite by email, accept via magic link, role on join.
6. **Admin / webmaster** — cross-org admin section to manage users and orgs.
7. **API scoping** — scope `/api/v1/*` to the token's org(s).
8. **Billing** — plans, Stripe subscriptions, plan-gated limits for the hosted tier.

## Authorization

Roles are implementation details; capabilities are the interface. Extend the existing `User#can?(action, record)` + `*Permission` pattern:

- `OrganizationPermission` — `manageable?` (owner), `viewable?` (member).
- Webmaster (`User#admin?`) short-circuits to allow across orgs.
- Controllers call `authorize!(:action, record)`; views gate with `can?`.

## Verification

- Model + integration tests per slice, written first.
- Cross-org access returns 404 (proven for servers + dashboard; extend to API).
- A second org's data never appears in any list, count, or detail view.
