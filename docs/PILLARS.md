# Conductor Pillars

Conductor is a control plane for self-hosted Rails operations — one place to run, monitor, and maintain apps across mixed infrastructure (Kamal + Docker, or native Caddy + Puma). The product is organized around six pillars. This doc is the map for understanding what each area does, how far along it is, and where contributions are most welcome.

> New here? Read `docs/VISION.md` for the why, then pick a pillar below. Each lists what exists today and concrete places to help.

## Status at a Glance

| # | Pillar | What it owns | Maturity |
|---|--------|--------------|----------|
| 1 | Fleet control | See apps, servers, issues, and state across the fleet | Strongest — usable today |
| 2 | Runtime backends | Deploy across Kamal/Docker and native Caddy/Puma | Working for Docker over SSH |
| 3 | Routing and edge | Caddy routes, domains, certificates, traffic | Early — baseline route CRUD |
| 4 | Provisioning and providers | Hetzner, Cloudflare, R2, SES, bootstrap flows | Early — mostly planned |
| 5 | Data and backups | Postgres backup, restore, monitoring | Backups work; restore is the gap |
| 6 | Continuous maintenance | Health checks, updates, drift detection, alerts | Recurring jobs run; depth pending |

Maturity is qualitative and moves often. For the current detailed assessment, see `docs/analysis/pillars-audit-2026-03-19.md`.

---

## 1. Fleet Control

**The single pane of glass.** Register servers, group their apps, and see health, last deploy, and current issues without SSH-ing into each box.

- **Today:** Server and app management, encrypted SSH key/credential storage, agentless SSH execution with live streaming output, server metrics, managed container status sync, and a dashboard that summarizes the fleet and surfaces issues.
- **Where help is wanted:** Multi-host orchestration (act across several servers at once), richer fleet filtering/grouping, and per-app history views.

## 2. Runtime Backends

**Deploy your way.** Conductor coordinates deployment tools as execution backends rather than forcing one model. Docker-over-SSH works today; native Puma/systemd and Kamal as a first-class backend are in progress.

- **Today:** Docker deployment pipeline over SSH, deploy log streaming via ActionCable, provisioning scripts (`server-provision`, `ruby-install`, `app-setup`, `app-deploy`, `systemd-setup`).
- **Where help is wanted:** Native Puma/systemd deploy completion, deeper Kamal lifecycle support, and rollback.

## 3. Routing and Edge

**Make apps reachable.** Conductor manages Caddy so adding or moving an app updates routing and TLS live, via Caddy's Admin API — no restart.

- **Today:** SSH-backed Caddy client for managed add/remove domain tooling (`CaddyClient`, `AddDomainTool`, `RemoveDomainTool`).
- **Where help is wanted:** Route persistence in the database, reconciliation/drift detection between Conductor and Caddy, deploy hooks, and certificate lifecycle tracking.

## 4. Provisioning and Provider Automation

**From created to ready.** Talk to provider APIs so servers, DNS, storage, and mail can be set up from one place.

- **Today:** Credential storage and the script-based provisioning lifecycle; provider API flows are largely planned.
- **Where help is wanted:** Hetzner VM creation, Cloudflare DNS record automation, R2 bucket management, SES verification, and an end-to-end server bootstrap flow.

## 5. Data and Backups

**Trustworthy data operations.** Back up Postgres on a schedule and — the key gap — restore and verify it.

- **Today:** Database backups to S3/R2-compatible storage, with scheduled backup triggering.
- **Where help is wanted:** Postgres restore execution, backup verification, and operational visibility into backup freshness/failures.

## 6. Continuous Maintenance

**Keep the fleet healthy over time.** Run recurring checks, surface failures, and detect drift before users notice.

- **Today:** Recurring ops baseline (metrics refresh, container sync, scheduled backups), dashboard issue detection, and critical-failure email alerts.
- **Where help is wanted:** Drift detection, auto-updates, certificate monitoring, historical metrics/trends, recurring-failure surfacing, and notifications beyond email (webhooks/Slack).

---

## How Pillars Relate

Pillar 1 (Fleet control) **displays** everything; Pillar 6 (Continuous maintenance) **monitors** everything. The other four are the systems being displayed and monitored. A change in routing or data shows up in the dashboard and gets watched by maintenance — so most features touch more than one pillar.

## Picking Up Work

1. Skim this page and pick a pillar that interests you.
2. Open `docs/plans/INDEX.md` for the capability plans (PRDs) grouped by pillar, with current status.
3. Read `docs/scenarios/` for end-to-end user flows that show how a pillar is meant to feel in practice.
4. Check `docs/analysis/pillars-audit-2026-03-19.md` for the honest current-state gaps.
