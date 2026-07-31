# Client Access and Managed Billing — Approved Design

**Approved:** 2026-08-01
**Canonical implementation contract:** [`docs/plans/01-client-access-managed-billing.md`](../../plans/01-client-access-managed-billing.md)
**Scenario:** [`SC-010`](../../scenarios/sc-010-client-access-managed-billing.md)

## Selected Approach

Ship a backup-first vertical slice, extended with fixed managed-server pricing:

1. resource-scoped memberships
2. shared client accounts and prepaid Stripe-funded wallets
3. immutable usage and money ledgers
4. client-specific backup prices
5. fixed shared-app and dedicated-server monthly prices
6. client and platform-admin dashboards

This proves authorization, funding, usage, charging, and reconciliation end to
end before SES/SNS reuse the same ledger.

## Approved Decisions

- Multiple clients stay inside one organization.
- Owners see all resources. Editors and members can see all or selected
  resources, bounded by any linked client account.
- Staff server grants include hosted apps; client-linked server grants require a
  same-client dedicated server. App grants do not expose the server.
- One client-account wallet is shared across its users and apps.
- Managed providers ship first; BYO is documented for later.
- Stripe Checkout funds an immutable Conductor ledger through verified webhooks.
- Admin controls client-specific rates and insufficient-credit behavior.
- Limited grace is the default so backups do not stop unexpectedly.
- Shared server space uses a fixed per-app monthly price.
- Dedicated clients may receive a fixed full-server monthly price.
- CPU/RAM/disk usage is visible but does not calculate v1 hosting charges.
- Internal server cost and margin remain admin-only.
- Hosted access charges one configurable client-account-month fee regardless of
  user count; internal/beta waivers require a reason and expiry.
- Self-hosted open-source mode bypasses commercial admission and billing gates.

## Alternatives Considered

| Approach | Why not selected |
| --- | --- |
| Generic billing foundation first | Would design abstractions before proving one real billable workflow |
| Access portal before billing | Safer but delays proving revenue and ledger behavior |
| Separate organization per client | Conflicts with the operator's shared-org fleet model |
| Balance per app | Fragments one client's funds and complicates multi-app management |
| Metered CPU/RAM hosting | Noisy, hard to explain, and unnecessary for initial server-space resale |
| Managed and BYO together | Doubles provider and pricing paths before managed billing is proven |

## Visual Review

- [Architecture](https://kuickr.co/conductor/brainstorm/client-billing-architecture.html)
- [Wallet and ledger](https://kuickr.co/conductor/brainstorm/client-billing-ledger.html)
- [Client and admin dashboards](https://kuickr.co/conductor/brainstorm/client-billing-dashboards.html)

The Kuickr visuals use the canonical Nodepad token system. The numbered Markdown
plan remains authoritative if visual copy ever drifts.
