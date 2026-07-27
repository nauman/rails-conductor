# 05 — SES email observability (event-level, via SNS)

Status: **Spec — DRAFT for annotation** (2026-07-27). Build SES *event-level*
observability into Conductor: per-message, per-recipient truth (deliveries,
bounces, complaints, opens, clicks) ingested from SNS, tied to the app/domain
that sent the mail. Design reference: **Sessy** (open-source SES observability by
Marc Köhlbrugge, Fizzy-inspired) — we adapt its model, not its codebase.

## Why this is worth doing

Conductor injects SES SMTP creds at deploy, so the fleet *sends* mail — but has
zero visibility into what happens after send. Roadmap **slot 20 (SES + SNS
messaging)** covers *aggregate* sending health (reputation, bounce/complaint
rates, verified identities) via the SES API. This spec is the **complementary
event stream**: "what happened to *this* email, to *this* recipient?" — the layer
people otherwise pay a glorified-SES-wrapper SaaS for. Owning it keeps the fleet
on raw SES while giving a single pane of glass in the control plane.

Slot 20 = the dashboard gauges (rates, reputation). This = the flight recorder
(every event, searchable, per message).

## What we take from Sessy (and where we diverge)

Sessy's shape is clean and battle-tested — we mirror it:

- **`SesEventPayload`** — a PORO that parses one SES event JSON (event type,
  `messageId`, recipients, timestamp, event-type-specific data). Port Sessy's
  `EventPayload` almost verbatim; it encodes the SES payload quirks (recipients
  live under `bounce`/`complaint`/`delivery`/… per type).
- **Idempotent ingestion** — `find_or_create` a message by `ses_message_id`, then
  `create_or_find_by!` an event on `(ses_message_id, event_type, recipient, event_at)`.
- **Raw webhook record** — persist the raw SNS payload for idempotency + replay.
- **SNS signature verification** — `Aws::SNS::MessageVerifier` (cached across
  requests — a fresh verifier re-downloads the signing cert ~600ms/req), plus
  auto-confirm `SubscriptionConfirmation`.
- **Retention policy** — auto-delete events/messages older than N days.

**Where Conductor diverges from Sessy (the real design work):**

1. **Org-scoped + multi-tenant.** Sessy is single-tenant. Conductor scopes every
   record to an `Organization` and the webhook token resolves the org.
2. **Events map to Apps/Domains.** Sessy's `Source` = an SES config set with a
   token. Conductor already knows apps + their domains, so the payoff is tying an
   event to the **App** that sent it (via sender domain / config-set mapping) —
   "app X has a 4% bounce rate this week," not just a standalone dashboard.
3. **Auto-wiring from Conductor.** Sessy makes you configure SES→SNS by hand.
   Conductor should *provision* the pipe (SES config-set event destination → SNS
   topic → Conductor's own webhook URL) from the SES-manage flow (slot 20 slice 2).
4. **Surfaced over MCP**, not just a UI — agents can query deliverability.

## Core model

- **`MessageStream`** (Sessy's `Source`) — the tokened webhook target,
  `belongs_to :organization`, unique `token` (webhook URL = `/webhooks/ses/:token`),
  optional link to an SES config-set name + a default App. Retention policy here.
  (Naming TBD — see Decision A; may just hang off `Organization` or `Domain`.)
- **`EmailMessage`** (Sessy's `Message`) — one email, keyed by `ses_message_id`;
  `source_email`, `subject`, `sent_at`, `mail_metadata` (json). `belongs_to
  :organization`, `belongs_to :app, optional: true`. `has_many :email_events`.
- **`EmailEvent`** (Sessy's `Event`) — one SES event for one recipient:
  `event_type`, `recipient_email` (normalized), `event_at`, `bounce_type`,
  `event_data` (json), `raw_payload`. `belongs_to :email_message` (+ counter
  cache), `organization`, optional `app`. Idempotent on the natural key.
- **`SesWebhook`** — raw SNS payload + processed flag (idempotent processing).
- **`SesEventPayload`** — PORO parser (ported from Sessy).

Event types: Send, Delivery, Bounce (Permanent/Transient/Undetermined),
Complaint, DeliveryDelay, Reject, Rendering Failure, Open, Click, Subscription.

## Data flow

1. SES config-set publishes events → **SNS topic** → `POST /webhooks/ses/:token`.
2. `Ses::WebhooksController` resolves the `MessageStream` by token, **verifies the
   SNS signature**, and on `SubscriptionConfirmation` auto-confirms.
3. On `Notification`: persist a `SesWebhook` (idempotent), enqueue processing.
4. `SesWebhook#process` builds a `SesEventPayload`, `find_or_create` the
   `EmailMessage`, then ingests `EmailEvent`s per recipient.
5. **Map to App**: resolve the sending domain (`source_email` → `Domain`/`App`),
   or the config-set → App mapping on the `MessageStream`; backfill `app_id`.

## Mapping events to apps (the Conductor-specific bit)

Two resolution paths, in order:

1. **Config-set → App** — if the `MessageStream` (or config-set) is bound to an
   App, every event on it attributes to that App. Cleanest when an app owns a
   config set.
2. **Sender domain → Domain/App** — parse `source_email`'s domain, match a
   Conductor `Domain` (which links to an App). Handles shared config sets.

Unmatched events still ingest (org-scoped, `app_id` nil) so nothing is lost.

## Auto-wiring (don't make the operator hand-configure SNS)

Building on slot 20's SES-manage client, Conductor should offer "**observe this
app's email**": create/confirm an SNS topic, set the SES config-set's event
destination to it, subscribe Conductor's `/webhooks/ses/:token` URL, and store the
`MessageStream`. One action, mirroring `put_behind_cloudflare`'s "one button"
ergonomics. Manual setup (paste the webhook URL into SES) stays supported.

## Surface

- **UI** — a deliverability view: per-App/Domain rates (delivery/bounce/complaint),
  a reverse-chronological event stream, search by recipient/subject, date + type
  filters (port Sessy's `Filterable`/`Searchable`). A message detail page
  (timeline of its events).
- **MCP** — `conductor_read action=email_events` (filter by app/domain/type/date;
  search) so agents can answer "why did mail to X fail?" Feeds situation reads.
- **Alerts** — bounce/complaint rate over threshold → the alerts pipeline
  (slot 12), complementing slot 20's aggregate reputation alert.

## Open questions / decisions to annotate

⟶ **Decision A (model home):** is the tokened webhook target a new
`MessageStream` model, or does it hang off `Organization` (one SES ingest URL per
org) or `Domain`? Proposed: a lightweight `MessageStream` (name + token +
optional app/config-set + retention), so an org can run several (per config set).

⟶ **Decision B (ingest sync vs async):** verify + persist the `SesWebhook`
synchronously (fast 200 to SNS), parse/ingest events in a Solid Queue job.
Proposed: **async** — SNS retries on non-2xx, and cert-verified persist is cheap;
parsing/mapping shouldn't block the webhook.

⟶ **Decision C (open/click tracking):** opens/clicks require SES *configuration
set* open/click tracking enabled (adds a tracking pixel/redirect). Ingest them
when present, but do we *enable* it during auto-wiring? Proposed: ingest always;
make enabling tracking an explicit opt-in (privacy).

⟶ **Decision D (retention default):** N days before auto-delete. Proposed: 30
days default, per-`MessageStream` override (Sessy-style).

## Implementation slices

1. **Ingest core** — `SesEventPayload` (port), `EmailMessage`/`EmailEvent`/
   `SesWebhook` models + migrations, idempotent ingest, org-scoped. Unit-tested
   against real SES payload fixtures.
2. **Webhook endpoint** — `Ses::WebhooksController`: `aws-sdk-sns` verifier
   (cached), subscription auto-confirm, async processing job.
3. **App/domain mapping** — config-set→App + sender-domain→Domain resolution;
   backfill `app_id`.
4. **Surface** — deliverability UI (rates + event stream + search/filter) +
   `conductor_read action=email_events` MCP + message detail.
5. **Auto-wiring** — provision SES config-set event destination → SNS → webhook
   from the SES-manage flow; retention job + threshold alert.

## Acceptance criteria

- [ ] A real SES SNS notification to `/webhooks/ses/:token` is signature-verified,
      ingested idempotently (replaying it creates no duplicates), and appears in
      the UI + over MCP within seconds.
- [ ] Events attribute to the correct App/Domain; unmatched events still ingest
      (org-scoped, `app_id` nil) and are visible.
- [ ] An operator sees per-app delivery/bounce/complaint rates and can search a
      recipient/subject to a message's full event timeline.
- [ ] Auto-wiring configures SES→SNS→Conductor end-to-end from one action;
      manual setup still works.
- [ ] Events past the retention window are auto-deleted; a bounce/complaint-rate
      threshold fires an alert.

## Test plan (sketch)

- `SesEventPayload` against captured fixtures for every event type (Sessy has
  these — reuse the shapes).
- Idempotent ingest: same payload twice → one message, N events, no dupes.
- Webhook: signature reject, subscription auto-confirm, async enqueue.
- Mapping: config-set-bound app; sender-domain match; unmatched → nil app.

## Relationship to the roadmap

Extends **slot 20 (SES + SNS messaging)** — slot 20 owns aggregate sending health
+ SES-manage + SMS; this owns the event stream and reuses slot 20's SES client for
auto-wiring. Alerts feed **slot 12**. Part of the *Connected Services* hub. Credit
+ design reference: [Sessy](https://github.com/marckohlbrugge/sessy) (O'Saasy
License — reference only; we implement independently in Conductor).
