# 0008. Observe the channels you configure

Date: 2026-08-27

## Status

**Accepted (2026-08-27).** Not implemented. Raised by the operator, who noticed
that neither they nor an agent could see mail failures anywhere in Conductor.

## Context

Conductor sets up email for the fleet. It stores the SES credential, verifies it
with a real STARTTLS `AUTH LOGIN` (`SesClient#verify`), knows the region, and even
writes the DNS that email depends on — `set_dns_record_tool` exists specifically to
create MX records for an SES custom MAIL-FROM bounce host.

Then it stops. There is no bounce record, no complaint record, no suppression
list, no send log, no delivery metric, no job that looks. Grep the schema for a
mail table and there is none; grep the jobs for a mailer check and there is none.

**So an app can be failing to deliver every message it sends and every Conductor
surface stays green.** The site check passes, the containers are healthy, the queue
is empty, the backups ran. Mail is not red — mail is *absent*, and absence reads
exactly like health.

This is the same failure this codebase keeps meeting from different directions.
The residue detector only inspected exited containers, so a live orphan ran for
fifteen days behind green checks. `paths-ignore` matched no files, so a merge
silently did not deploy. In each case **green meant "nothing looked here", and
nothing distinguished that from "nothing is wrong"**.

Email deserves its own entry because its failure mode has a cliff in it. Most
outages degrade: a slow box gets slower, a full disk fills. SES suspends sending
when bounce or complaint rates cross a threshold — the account goes under review
and stops delivering, and the first symptom is usually a customer saying they never
got the mail. The suppression list is quieter still: addresses are dropped
silently, permanently, with a `250 OK` on the wire. **A successful SMTP handshake
is not a delivered email**, and credential verification — the only thing Conductor
does today — confirms only the handshake.

There is a second-order cost too. Conductor is the fleet's memory for agents. An
agent debugging "the customer never got the invite" has nowhere to look, so it does
what I did tonight with containers: SSH in and reconstruct. That is the archaeology
ADR 0007 exists to stop.

## Decision

**A channel Conductor configures is a channel Conductor must be able to observe.**

If Conductor holds the credential, it owns the question "is this working?" — not
merely "are these credentials valid?". Configuration without observation is a
half-integration, and the missing half is the one that fails at 3am.

For email specifically, in cost order:

1. **Account health** — is sending enabled at all, and what are the current bounce
   and complaint rates against their thresholds? One poll, no per-app wiring, and
   it catches the cliff. This is the piece that would have mattered most.
2. **Suppression list** — size, and whether a given address is on it. Turns "they
   never got it" from a mystery into a lookup.
3. **Per-app delivery events** — bounces, complaints, deliveries. At least one app
   already publishes SES events to SNS (`SES_EVENTS_TOPIC_ARN` is in its deploy
   env), so the events exist; nothing consumes them at the fleet level.

Surfaced the way everything else is: a finding in the situation worklist when
sending is paused or a rate is approaching its threshold, carrying a diagnostic
recipe per ADR 0007.

## Consequences

**Accepted:**
- A new integration is not finished when the credential verifies. "What does
  failure look like, and where would someone see it?" becomes part of adding one.
- This generalises past email. Any outbound channel Conductor configures — object
  storage, DNS, a webhook, a registry — inherits the same obligation.

**Costs:**
- **SES SMTP credentials are not SES API credentials.** The stored SMTP
  username/password authenticate the mail submission endpoint and cannot call
  `GetAccount` or the suppression API. Account health needs an IAM access key with
  SES read permissions — a genuinely new credential to store and scope, and the
  main reason this is not a small change.
- Consuming SNS delivery events means an endpoint, subscription confirmation, and
  signature verification. Real work, which is why it is ranked last.

**Rejected:**
- *Treat credential verification as monitoring.* It proves the handshake and
  nothing about delivery. This is the status quo, and it is what produced the gap.
- *Leave it to each app.* Apps that handle their own SES events do so in isolation;
  the fleet-level question — is this account about to be suspended, taking every
  app with it — has no per-app answer.

## Status detail

| Step | State |
|---|---|
| Decision recorded | Done — this ADR |
| SES account health (sending enabled, bounce/complaint rates) | Not built |
| Suppression-list read | Not built |
| SNS delivery-event consumption | Not built |
| `email_delivery` finding + diagnostic recipe | Not built |

Related: ADR 0007 (findings cite rituals),
`docs/learnings/a-findings-remedy-is-a-production-action.md`.
