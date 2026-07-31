# Multi-Tenancy & Accounts Plan

## Pillar
Cross-cutting (Tenancy & Accounts)

## Status
Partial — org models, scoping, switching, onboarding, invitations, admin, API
scoping, and three-tier roles shipped. Resource-scoped memberships and managed
billing are approved but not implemented.

## Current Reality

- `Organization` + `Membership` models exist; a user can belong to many orgs
  with a `member`, `editor`, or `owner` role.
- Every user has at least one org (`User#ensure_personal_organization!`); the first user bootstraps as the platform admin.
- `Current.organization` is set per request; a nav switcher changes the active org.
- `Server`, `App`, `Credential`, `Backup`, `SshKey` carry `organization_id` and are loaded/created strictly via `current_organization`. The dashboard is scoped too. Cross-org access returns 404.
- Signup is invite-only (no auto-account creation).
- The JSON API (`/api/v1/*`) is org-scoped: requests operate within the token's organization, tokens are rejected once their user leaves that org, and read-only tokens cannot write. Action Cable is authenticated and org-scoped too.

## Goal

Make Conductor a safe multi-tenant product: every tenant (organization) sees only its own infrastructure, owners can invite teammates, a platform webmaster can administer the whole instance, and a hosted tier can charge for usage — without leaking data across tenants.

## Scope

- Organizations as the unit of tenancy; users join via memberships with roles.
- Per-org isolation across all resources, the dashboard, and the JSON API.
- Smooth first-run onboarding (see `docs/plans/onboarding.md`).
- Invitations: owner invites by email → magic link → joins the org.
- Platform admin (webmaster) section: manage users/orgs across the instance.
- Paid hosted services: client-specific prepaid credit for managed backups and
  fixed shared-app/dedicated-server capacity, plus one configurable monthly
  hosted-platform fee per client account. See
  [`01-client-access-managed-billing.md`](./01-client-access-managed-billing.md).

## Non-goals

- Per-resource deny rules. V1 resource grants are additive (`all` or selected
  app/server access) and still constrained by role capabilities.
- SSO/SAML in the first pass.
- CPU/RAM/disk metering, multi-currency wallets, and automated proration.

## Slices

1. **Models** — `Organization`, `Membership`, roles. ✅ shipped
2. **Auth wiring** — personal org, `Current.organization`, switcher. ✅ shipped
3. **Resource scoping** — `organization_id` + scoped controllers + dashboard. ✅ shipped
4. **Onboarding** — first-run org naming + empty-state guidance. ✅ shipped (`docs/plans/onboarding.md`)
5. **Invitations** — invite by email, accept via tokened link, role on join. ✅ shipped
6. **Admin / webmaster** — cross-org admin section (`/admin`) for orgs + users. ✅ shipped
7. **API scoping** — `/api/v1/*` scoped to the token's org, membership-revoked, read/write scopes. ✅ shipped
8. **Resource access** — owners remain organization-wide; editors/members gain
   `all` or selected app/server access. ⚪ approved in plan 01
9. **Managed billing** — client accounts, Stripe-funded credit ledger, backup
   usage, and fixed server-space resale. ⚪ approved in plan 01

## Authorization

Roles are implementation details; capabilities are the interface. Extend the existing `User#can?(action, record)` + `*Permission` pattern:

- `OrganizationPermission` — `manageable?` (owner), `viewable?` (member).
- Webmaster (`User#admin?`) short-circuits to allow across orgs.
- Controllers call `authorize!(:action, record)`; views gate with `can?`.

## Verification

- Model + integration tests per slice, written first.
- Cross-org access returns 404 (proven for servers + dashboard; extend to API).
- A second org's data never appears in any list, count, or detail view.
