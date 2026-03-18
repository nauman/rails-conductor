# Conductor Vision

## Core Vision

**Conductor is the control plane for self-hosted Rails operations.**

It gives developers one place to run, monitor, and maintain apps across mixed infrastructure. Some apps may run with Kamal and Docker. Others may run natively on multi-app servers with Caddy and Puma. Conductor should work across both without forcing one deployment style.

The product is not just about shipping code. It is about operating the full system after deploy: servers, apps, routing, databases, backups, storage, mail, and ongoing maintenance. It should connect to the tools developers already use, including existing CLIs and provider APIs, and turn them into one coherent operational layer.

Conductor should make it possible to:
- see the health of the whole fleet quickly
- deploy and manage apps across different runtime models
- provision and maintain servers without constant SSH work
- manage DNS, object storage, and email infrastructure through APIs
- run Postgres infrastructure with backups and operational visibility
- keep servers updated and continuously checked for drift or failures

## Positioning

**Conductor unifies self-hosted Rails operations across apps, servers, and infrastructure providers.**

Run your apps your way. Conductor gives you one control plane for deployments, routing, databases, backups, provider APIs, and server maintenance.

## Operating Model

Conductor sits above infrastructure tools instead of forcing a complete replacement of them. It should be able to coordinate SSH workflows, provider APIs, and existing CLIs as execution backends inside one operational system.

That means Conductor can work with:
- Kamal for Docker-based deployments
- ONCE-compatible runtimes or CLI workflows where they fit
- native Caddy/Puma setups for multi-app servers without Docker
- provider APIs such as Hetzner, Cloudflare, R2, and SES
- database and backup tooling needed to manage Postgres clusters

Conductor should remain compatible with lower-level tools without depending on any single one of them. It should be able to use those tools as execution backends where they add leverage, while still owning the fleet model, routing, provider workflows, and ongoing operations.

## Moat

**The moat is not deployment by itself. The moat is unified operations across mixed infrastructure.**

What should make Conductor defensible:
- Kamal and native hosting in one system
- multi-host Caddy orchestration
- deep provider workflows for Hetzner, Cloudflare, R2, and SES
- Postgres cluster lifecycle management
- continuous maintenance, updates, health checks, and drift detection
- a single UI, API, and CLI layer above existing tools

## Current State

Conductor is not at the full vision yet. Today it is best understood as a fleet dashboard with working deploy, backup, and alerting primitives plus a large amount of strategic surface still unbuilt.

What works today:
- basic Docker deploys over SSH
- server provisioning scripts
- backup creation and scheduling
- critical failure alerts by email
- dashboard visibility into current fleet status

What is still the critical gap:
- Caddy routing and Admin API integration
- provider APIs for Hetzner, Cloudflare DNS, SES, and R2 management
- Postgres restore and operational checks
- recurring maintenance jobs, auto-updates, and drift detection
- multi-host orchestration across the fleet

## Strategic Pillars

1. **Fleet control** — one place to see apps, servers, issues, and operational state across the fleet
2. **Runtime backends** — support Kamal, ONCE-compatible Docker workflows, and native Caddy/Puma servers
3. **Routing and edge** — multi-host Caddy orchestration, domains, certificates, and traffic state
4. **Provisioning and provider automation** — domains, Hetzner, Cloudflare, R2, SES, and control-panel setup flows
5. **Data and backups** — Postgres backup, restore, monitoring, and cluster lifecycle
6. **Continuous maintenance** — server checks, updates, drift detection, and alerts

## What Conductor Is

**Conductor is a self-hosted ops control panel for indie developers who deploy their own way.**

It's the single pane of glass to see:
- What servers are running and their health
- What apps are deployed and their status
- What's going wrong (issues, failed deployments, offline servers)
- Database backups and their status

## What Conductor Is NOT

- **Not a locked-in hosting platform** — You keep your own servers and deployment choices
- **Not a single-runtime deployment tool** — It should work across Docker and native hosting models
- **Not just monitoring** — It should help operators take action, not only observe

## The Core Philosophy

> "I can deploy myself. What I need is visibility and quick actions."

Conductor respects that you:
1. **Own your servers** (Hetzner, DigitalOcean, Vultr, whatever)
2. **Deploy your way** (Kamal, native Puma/systemd, or both)
3. **Want one place to see everything** (not 5 different dashboards, not a custom admin panel in every app)

---

## The Two Tools

### 79-conductor — Execution Engine
The ops panel. Connects to your fleet via SSH, shows health, runs deploys, manages Caddy, runs provisioning scripts. This is the thing that actually does work.

### conductor — AI Chat Interface
Natural language orchestration on top of the execution engine. You say:

> "Move platepose.com, minimalnarrow.com, and agpages.com.au to one server, set up R2 backups and image storage for all of them, and create a Postgres cluster."

It should be able to plan and execute that with clear operational steps, using the same underlying execution engine instead of inventing a separate system.

---

## The 4 Deployment Types

```
1. Kamal single    → Docker + Caddy, one app, one server
2. Kamal multi     → Docker, multiple apps, one server
3. Native single   → Puma systemd + Caddy, one app, one server
4. Native multi    → Puma systemd + Caddy, many apps, one server
```

Types 3 and 4 matter because they let Conductor support cost-efficient multi-app hosting without forcing Docker everywhere.

---

## Native Multi-App Stack (Type 4)

This is what you get on a server with multiple apps deployed natively:

```
Server
├── Caddy (reverse proxy + Let's Encrypt + Admin API on :2019)
│   ├── platepose.com      → /tmp/puma-platepose.sock
│   ├── minimalnarrow.com  → /tmp/puma-minimalnarrow.sock
│   └── agpages.com.au     → /tmp/puma-agpages.sock
├── PostgreSQL (one cluster, one database per app)
│   ├── platepose_production
│   ├── minimalnarrow_production
│   └── agpages_production
├── Redis (shared)
└── deploy user
    ├── ~/.asdf/ruby (shared Ruby version)
    ├── puma-platepose.service     (systemd user service)
    ├── puma-minimalnarrow.service (systemd user service)
    └── puma-agpages.service       (systemd user service)
```

---

## The Caddy API Integration

This is what makes Conductor genuinely powerful — and what no other tool does cleanly.

**Caddy's Admin API runs on port 2019 and accepts live config changes without a restart.**

- When you add an app → Conductor calls Caddy API to add the route immediately
- When you remove an app → Conductor removes the route, SSL certificate cleans up
- When you move an app between servers → Conductor updates both Caddy instances

**Apps can also call Conductor's API:**

```
POST   /api/v1/domains    → add a domain/subdomain to Caddy
DELETE /api/v1/domains    → remove a domain
GET    /api/v1/health     → fleet health summary
```

This means MadeMySite's custom domain feature (user brings their own domain) doesn't need DNS magic — it calls Conductor, Conductor calls Caddy.

---

## Provisioning Scripts

Conductor stores bash scripts in the database and runs them over SSH with live streaming output. Five built-in scripts cover a server lifecycle:

| Script | Type | What it does |
|---|---|---|
| `server-provision` | provision | Bootstrap Ubuntu: deploy user, Caddy, PostgreSQL, Redis, UFW |
| `ruby-install` | provision | ASDF + Ruby as deploy user |
| `app-setup` | setup | Directory structure, git clone, shared config, .env |
| `app-deploy` | deploy | Bundle, migrate, assets, symlink current, restart Puma |
| `systemd-setup` | setup | Write Puma socket + service files, enable linger |

Scripts are editable, versioned, and runnable from the UI against any server in the fleet. Output streams live to the browser via ActionCable.

---

## Why This Matters

- Developers can keep using the tools and deployment styles they already trust
- Small VPS fleets can mix Docker apps and native apps under one control plane
- Routing, backups, provider APIs, and server maintenance become shared infrastructure instead of ad hoc scripts
- Teams stop rebuilding one-off admin panels inside every app just to see operational state

---

## What Success Looks Like

A developer running 8+ apps across 3+ providers can:

1. **See the whole fleet in 10 seconds** — health, last deploy, current commit across all apps
2. **Move 3 apps to one server in one command** — AI chat orchestrates provisioning + deploy + Caddy setup
3. **Never build `/admin/server` in an app again** — Conductor replaces per-app monitoring panels
4. **Know about problems before users do** — uptime checks + alerts for agpages.com.au (client app)
5. **Add a custom domain in one API call** — apps call Conductor, Conductor calls Caddy

---

## Technical Principles

1. **SSH, not agents** — No software to install on servers
2. **Encrypted secrets** — SSH keys and API credentials stored encrypted
3. **Streaming output** — All long-running operations (provision, deploy) stream live via ActionCable
4. **Background jobs** — Metrics polling, deploys, backups all async via Solid Queue
5. **Rails 8** — Turbo, Solid Queue, Tailwind, Solid Cable

---

## Build Order

### Phase 1: Make the core loop work
1. **Caddy API integration** — deploy, route, and make apps reachable
2. **Recurring jobs** — metrics, container sync, and backups on schedule
3. **Postgres restore** — make backup trustworthy operationally

### Phase 2: Automate infrastructure
4. **Hetzner API integration** — provision servers from Conductor
5. **Cloudflare DNS integration** — connect domains and records
6. **Bootstrap flow** — take a new server from created to ready

### Phase 3: Build the fleet moat
7. **Kamal and optional ONCE-compatible backend integration** — support richer Docker lifecycle workflows
8. **Multi-host orchestration** — coordinate actions across servers
9. **Continuous maintenance** — drift detection, updates, cert monitoring, and trends

### Phase 4: Deliver one-click product UX
10. **Provisioning wizard** — server, domain, and app in one flow
11. **Webhook and Slack notifications** — beyond email alerts
12. **AI orchestration layer** — natural language workflows on top of the control plane

---

## Target User

**Indie developer managing 2–10+ servers across multiple providers who:**
- Has a mix of Kamal and native deployments
- Is tired of SSHing into servers individually
- Has built custom admin panels in multiple apps just to see health
- Doesn't want to pay per-server fees to a platform they don't control

---

## The Name

**Conductor** — orchestrates visibility and action across your fleet, like a conductor who sees the whole system and keeps it moving.
