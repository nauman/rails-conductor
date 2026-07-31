# SC-010: Client Access and Managed Billing

## User Story (Raw)

> i am thining to per app we can add client as well and give him credit strip interface
>
> so i can pay for backups
> SES/SNS
>
> and we build dashboard for them and we have admin interface to set pricing so we can charge per client diferent, this is opensource product but this means that we can charge clients then like agpages

## Actors

| Actor | Description |
| --- | --- |
| Platform Admin | Hosts Conductor, owns provider/server spend, assigns access, pricing, and credit policy |
| Access Requester | Wants to use the live hosted instance but has no approved account yet |
| Organization Owner | Has organization-wide access and existing owner-only capabilities |
| Editor | Operates all or selected resources within existing editor capabilities |
| Member | Views all or selected resources within existing member capabilities |
| Client Account | Shared commercial account for one client, its users, apps, wallet, and rates |
| Stripe | Collects prepaid funds through hosted Checkout and sends verified webhooks |
| Managed Backup Provider | Stores client backups through credentials paid by the platform operator |
| Managed Server | Dedicated or shared capacity resold by the platform operator |

## Goals

1. Keep several clients inside one organization without exposing unrelated resources.
2. Let owners, editors, and members use `all` or selected resource visibility as designed.
3. Give each client one prepaid balance shared across its users and apps.
4. Charge client-specific prices for managed backups and server space.
5. Let the admin control costs, sell rates, grace, assignments, and corrections.
6. Preserve a later path for SES, SNS, and bring-your-own provider credentials.
7. Prevent unapproved or unfunded users from consuming the live hosted instance.

## Scenario Flow

### Scenario 10.0: Admin admits a hosted client

**Preconditions:** Hosted billing is enabled; requester has no Conductor account.

**Flow:**
1. Requester submits an access request; no user, org, app, or server is created.
2. Admin approves the request and creates/links a `pending` client account.
3. Admin sets one monthly platform-access price, independent of user count.
4. Client adds initial credit, or admin grants an internal/beta waiver with expiry.
5. A verified top-up or effective waiver atomically activates the client; the
   client then receives configured app/server/job/API/MCP/log limits.

**Acceptance Criteria:**
- [ ] Unknown sign-in emails never create access.
- [ ] Pending clients can reach only activation/top-up surfaces.
- [ ] Only verified posted credit or an effective waiver can transition a
      client account from pending to active.
- [ ] Internal and beta waivers have reasons and expiry dates.
- [ ] Limits reject new work visibly without stopping existing apps.
- [ ] Open-source self-hosted mode has no commercial admission gate or fee.

### Scenario 10.1: Admin creates a client and grants selected access

**Preconditions:** Platform admin is signed in; the organization, client users, apps, and servers exist.

**Flow:**
1. Admin creates a client account in the organization.
2. Admin links the client's memberships and billable apps.
3. Admin sets each editor/member scope to `all` or `selected`.
4. For selected scope, admin grants apps and/or servers.
5. Conductor applies the same accessible-resource resolver across every surface.

**Acceptance Criteria:**
- [ ] Owners remain organization-wide.
- [ ] Editors and members may use either scope without changing role capabilities.
- [ ] A staff server grant includes hosted apps; a client-linked server grant is
      allowed only for a same-client dedicated server.
- [ ] A client-linked membership cannot receive a shared/mixed-client server grant.
- [ ] Client-linked `all` stops at that client account's resources.
- [ ] An app grant does not reveal unrelated server/fleet data.
- [ ] Cross-organization grants are rejected.
- [ ] Web, API, MCP, dashboards, counts, and live streams agree.

### Scenario 10.2: Client prepays through Stripe

**Preconditions:** Client account is pending or active and has a Stripe customer.

**Flow:**
1. Client opens the billing dashboard and chooses a top-up amount.
2. Conductor redirects to Stripe Checkout.
3. Stripe accepts payment and redirects the client to a processing page.
4. A signature-verified webhook posts one immutable top-up entry.
5. Client dashboard shows the new balance and ledger activity.

**Acceptance Criteria:**
- [ ] Browser redirects cannot create credit.
- [ ] Duplicate webhooks cannot duplicate credit.
- [ ] Balance equals the sum of immutable ledger entries.
- [ ] Aggregate wallet totals may be shared, but ungranted app/server identities
      are redacted from detailed client rows.
- [ ] Payment/card details do not enter Conductor logs or records.

### Scenario 10.3: Managed backup consumes credit

**Preconditions:** App belongs to the client account; managed backup and rates are active.

**Flow:**
1. Scheduled backup checks the client's balance and credit policy.
2. Backup runs when positive credit or configured grace permits it.
3. Successful completion records an idempotent operation usage event.
4. Conductor snapshots the effective client price and posts one debit.
5. Storage GB-month charging begins only when retained artifact inventory is reliable.

**Acceptance Criteria:**
- [ ] Backup success and billing success are separate states.
- [ ] Retries never double-charge.
- [ ] Historical charges retain the original price.
- [ ] Client sees backup status, usage, and charge without unrelated fleet data.

### Scenario 10.4: Admin resells server space

**Preconditions:** Client has an app on a shared server or controls a dedicated server.

**Flow:**
1. Admin records the server's internal monthly cost.
2. Admin assigns shared app hosting or dedicated server hosting to the client.
3. Admin sets a client-specific fixed app-month or server-month sell price.
4. On the assignment anniversary, Conductor posts one fixed-period usage event and debit.
5. Admin sees projected margin; client sees only their sell price and charge.

**Acceptance Criteria:**
- [ ] Shared app and dedicated server assignments cannot conflict.
- [ ] A dedicated assignment cannot cover a server containing any nil-client or
      other-client app, whether billed or not.
- [ ] Internal cost and margin are admin-only.
- [ ] CPU/RAM metrics do not change the v1 charge.
- [ ] Monthly retries cannot duplicate charges.
- [ ] Mid-cycle changes use explicit adjustments; no hidden automatic proration.

### Scenario 10.5: Client enters grace

**Preconditions:** Client balance is insufficient for a new managed charge.

**Flow:**
1. Conductor applies the client account's `grace` or `hold` policy.
2. Under default grace, an operation that stays within the limit proceeds.
3. Client and admin receive low/negative-balance visibility.
4. A new operation that would exceed grace is held and surfaced for action.
5. Existing apps, data, and dashboard access remain intact.

**Acceptance Criteria:**
- [ ] Grace amount and alert threshold are admin-configurable.
- [ ] Scheduled work is never silently discarded.
- [ ] Credit exhaustion never automatically destroys or stops client infrastructure.
- [ ] Admin can post a reasoned adjustment or request a Stripe top-up.

## Data Model Implications

- Add `ClientAccount`, shared by client memberships and billable apps.
- Add hosted lifecycle, platform-access fee/waiver, and client limit policy.
- Add `Membership#resource_scope` and polymorphic `ResourceGrant` rows for apps/servers.
- Add optional `App#client_account_id` for future usage attribution.
- Add versioned `ServerCost` and client-specific `PriceRate` records.
- Add `ManagedServiceAssignment` for shared-app and dedicated-server hosting periods.
- Add idempotent `UsageEvent` and immutable `LedgerEntry` records.
- Add Stripe `TopupIntent`, atomic credit reservations, and resumable managed-operation holds.
- Keep all money in integer minor units and one currency per client wallet.

See [`docs/plans/01-client-access-managed-billing.md`](../plans/01-client-access-managed-billing.md) for the canonical contract.

## Technical Notes

- Resource visibility and role capabilities are independent, cumulative checks.
- Stripe Checkout funds the wallet; verified webhooks create credit.
- Hosting prices are fixed monthly allocations, not resource metering.
- Backup storage charging depends on trustworthy artifact tracking and retention.
- Managed SES/SNS later emit usage events into the same ledger.
- BYO provider mode later skips managed-provider debits.

## Open Questions

No product-design question blocks implementation planning. Tax/invoice policy
must be settled before a public paid launch; v1 remains suitable for a private
hosted beta using Stripe receipts.

## Priority

**High.** This turns Conductor's existing tenancy, backups, and fleet model into
a coherent managed-service business without weakening the open-source product.
