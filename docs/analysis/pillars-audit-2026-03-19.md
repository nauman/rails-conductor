# Conductor Pillars Audit — March 19, 2026

## Product Thesis

Conductor is building toward a control plane for self-hosted Rails operations: one system to manage
apps, servers, routing, backups, databases, provider APIs, and maintenance across mixed infrastructure.

## Current Product Reality

Today Conductor is a fleet dashboard with working deploy, backup, and alerting primitives plus a
large amount of strategic surface still unbuilt. The audit below measures that gap directly.

## Strategic Pillars

1. **Fleet control** — Visibility into apps, servers, issues, and operational state
2. **Runtime backends** — Kamal, optional ONCE-compatible Docker workflows, and native deploys
3. **Routing and edge** — Caddy orchestration, domains, certificates, and reachability
4. **Provisioning and provider automation** — Domain, server, DNS, storage, and email setup from the control panel
5. **Data and backups** — Postgres backup, restore, monitoring, and cluster lifecycle
6. **Continuous maintenance** — Updates, drift detection, recurring checks, and alerts

## Detailed Implementation Pillars

1. **Kamal Docker-based app management** — Deploy, manage, and orchestrate Docker containers via Kamal
2. **Native multi-host Caddy stack** — Deploy Puma/systemd apps with Caddy reverse proxy, no Docker required
3. **Full provider API support** — SES, R2, Hetzner, Cloudflare DNS as first-class integrations
4. **Postgres cluster management** — Backup, restore, monitoring, failover, upgrades
5. **Automatic server updates and continuous checks** — Always-on fleet hygiene
6. **One-click infrastructure provisioning** — Buy domains, provision Hetzner servers, and wire Caddy routing from one platform

---

## Pillar 1: Kamal Docker-Based App Management

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Docker image building | COMPLETE | Local build on server via SSH |
| Container start/stop/restart | COMPLETE | Direct Docker commands |
| Deployment streaming | COMPLETE | ActionCable real-time logs |
| Health checks | COMPLETE | Configurable `/up` with retries |
| Container status sync | COMPLETE | `docker inspect` polling |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Kamal CLI integration | MISSING | Gem installed but unused — deploys use raw Docker commands |
| Kamal config generation | MISSING | No dynamic config per managed app |
| Registry push/pull | MISSING | Build-only, no remote registry support |
| Rollback | MISSING | No image/release history |
| Multi-host rolling deploys | MISSING | Each app tied to single server |
| Blue-green / canary | MISSING | No versioned deployment strategies |

### Key Files

- `app/services/app_deployer.rb` — Docker deployment orchestration
- `app/jobs/deploy_app_job.rb` — Routes to Docker or native deployer
- `app/models/deployment.rb` — Deployment states and lifecycle
- `app/services/container_status.rb` — Docker inspect parsing
- `app/channels/deploy_channel.rb` — Real-time log streaming

### Verdict

Basic Docker deploy works end-to-end. But it's raw `docker build && docker run`, not Kamal.
The Kamal integration that would differentiate this (rolling deploys, registry, rollback,
accessories) is unbuilt.

### Priority Gaps

1. Kamal CLI wrapper service — generate config, invoke `kamal deploy`, parse output
2. Registry credential management per app
3. Release/image versioning for rollback
4. Multi-server deployment orchestration

---

## Pillar 2: Native Multi-Host Caddy Stack

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Native/systemd deployer | PARTIAL | Scripts exist, flow works |
| Provisioning scripts | COMPLETE | 5 built-in scripts (server, ruby, app-setup, systemd, deploy) |
| Caddy installation | COMPLETE | In server-provision script |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Caddy Admin API client | MISSING | Zero implementation — tools are stubs |
| Dynamic route management | MISSING | Can't add/remove routes at runtime |
| SSL/TLS certificates | MISSING | `ssl_enabled` flag only, no cert lifecycle |
| Multi-app routing | MISSING | Schema supports it, no Caddy sync |
| Port allocation | MISSING | Manual assignment, no conflict detection |
| Route drift detection | MISSING | No comparison of desired vs actual Caddy config |

### Key Files

- `app/services/native_deployer.rb` — Systemd deployment orchestration
- `app/tools/add_domain_tool.rb` — STUBBED, no actual API calls
- `app/tools/remove_domain_tool.rb` — STUBBED, no actual API calls
- `db/seeds.rb` — Built-in provisioning scripts (lines 152-392)
- `caddy_ops_ui_architecture.md` — Architecture vision (unimplemented)

### Verdict

You can provision a server and deploy a Puma app via systemd. But traffic won't reach it —
the Caddy routing layer that connects domains to apps doesn't exist. This is the single
biggest gap in the entire system.

### Priority Gaps

1. `CaddyClient` service — HTTP client for Caddy Admin API (port 2019)
2. Route CRUD: add route, remove route, list routes, validate routes
3. Auto-port allocation with conflict detection
4. Route sync job — reconcile desired state (DB) with actual state (Caddy)
5. Certificate status queries via Caddy API

---

## Pillar 3: Full Provider API Support

### What's Built

| Provider | Capability | Status | Detail |
|---|---|---|---|
| AWS SES | SMTP sending | PARTIAL | SMTP configured, mailers work |
| Cloudflare R2 | Backup uploads | PARTIAL | S3-compatible CLI via SSH |
| Credentials | Encrypted storage | COMPLETE | Full CRUD, encrypted at rest |

### What's Missing

| Provider | Capability | Status | Detail |
|---|---|---|---|
| AWS SES | Domain verification | MISSING | No SES API integration |
| AWS SES | Bounce/complaint handling | MISSING | — |
| Cloudflare R2 | Bucket management | MISSING | No API client |
| Hetzner | Server provisioning API | MISSING | Model field only |
| Hetzner | Server management | MISSING | No API |
| Cloudflare DNS | Record management | MISSING | Stub tools only |
| Cloudflare DNS | Zone management | MISSING | — |
| All providers | Credential validation | MISSING | Keys saved but never tested against API |

### Key Files

- `app/models/credential.rb` — Encrypted provider credentials
- `app/services/database_backup.rb` — R2/S3 upload via CLI
- `app/mailers/alert_mailer.rb` — SES-backed email delivery
- `config/environments/production.rb` — SES SMTP config
- `Gemfile` — `aws-sdk-ses`, `aws-sdk-s3` gems installed

### Verdict

Credentials are stored securely. Backups upload to R2/S3 via CLI. Everything else is a stub
or missing. No direct SDK usage for any provider.

### Priority Gaps

1. Hetzner API client — list/create/delete servers, SSH key management
2. Cloudflare DNS API client — zone listing, record CRUD
3. SES domain verification flow
4. Credential validation (test API key before saving)

---

## Pillar 4: Postgres Cluster Management

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Backup creation (pg_dump) | COMPLETE | Compressed, uploaded to cloud storage |
| Backup scheduling | COMPLETE | hourly/daily/weekly/monthly via Solid Queue |
| Backup failure alerts | COMPLETE | Email to admins |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Restore | MISSING | Zero restore functionality |
| Backup verification | MISSING | No integrity checks |
| Restore drills | MISSING | — |
| Cluster creation | MISSING | Generic script framework only |
| Replication / failover | MISSING | — |
| DB health monitoring | MISSING | No pg_isready, no query stats |
| Version upgrades | MISSING | — |
| Connection pool monitoring | MISSING | — |

### Key Files

- `app/services/database_backup.rb` — pg_dump + cloud upload
- `app/jobs/backup_job.rb` — Backup execution
- `app/jobs/run_scheduled_backups_job.rb` — Backup scheduler
- `app/models/backup.rb` — Backup model with scheduling
- `app/mailers/alert_mailer.rb` — Failure notifications

### Verdict

Backup pipeline is solid and production-ready. But you can back up and never restore — that's
half the value. Cluster creation, replication, failover, and monitoring are all unbuilt.

### Priority Gaps

1. `pg_restore` integration — restore from cloud backup
2. Backup integrity verification (test restore to temp DB)
3. Database health monitoring (pg_isready, connection counts, replication lag)
4. Postgres provisioning automation (install, configure, create databases)

---

## Pillar 5: Automatic Server Updates & Continuous Checks

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Server metrics (CPU/RAM/disk) | PARTIAL | Collection works, NOT scheduled |
| Dashboard issue aggregation | PARTIAL | Shows offline, high CPU/disk, failed deploys |
| Backup failure email alerts | COMPLETE | End-to-end |
| Server offline email alerts | COMPLETE | End-to-end |
| Deployment failure alerts | COMPLETE | End-to-end |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Recurring job scheduling | PARTIAL | Framework exists, only 1 job configured |
| Auto security updates | MISSING | No unattended-upgrades automation |
| Drift detection | MISSING | Mentioned in docs, zero code |
| Certificate expiry monitoring | MISSING | — |
| Disk pressure email alerting | MISSING | Dashboard only, no notification |
| Historical metrics / trends | MISSING | Snapshots only, no time-series |
| Slack/webhook notifications | MISSING | Email only |

### Key Files

- `app/services/server_metrics.rb` — CPU, memory, disk collection via SSH
- `app/jobs/refresh_server_metrics_job.rb` — Metrics refresh (not scheduled)
- `app/jobs/sync_container_status_job.rb` — Container polling (not scheduled)
- `app/mailers/alert_mailer.rb` — Email alerts
- `config/recurring.yml` — Only 1 recurring job configured
- `app/controllers/dashboard_controller.rb` — Issue aggregation

### Verdict

The alert mailer works for critical paths. But metrics aren't on a recurring schedule,
there's no auto-updates, no drift detection, and no historical data. The "always-on"
daily-use product isn't there yet.

### Priority Gaps

1. Configure recurring jobs in `recurring.yml` (metrics, container sync, backup scheduler)
2. Server update automation (unattended-upgrades setup and monitoring)
3. Drift detection: compare expected config vs actual server state
4. Certificate expiry tracking and alerting
5. Historical metrics table for trend analysis

---

## Pillar 6: One-Click Infrastructure Provisioning

**Buy domains, provision servers, and wire routing — all from Conductor.**

This is the ease-of-use layer that makes Conductor a complete platform rather than a collection
of ops tools. A user should be able to go from "I need a new app" to "it's live at my domain"
without leaving Conductor.

### The Flow

```
Buy/connect domain (Cloudflare) → Provision server (Hetzner) → Deploy app → Wire Caddy route → Live
```

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Server model with provider/region | COMPLETE | Schema tracks provider, region, IP |
| Credential storage for providers | COMPLETE | Encrypted API keys for Hetzner, Cloudflare |
| App domain field | COMPLETE | Stored in database |
| Server provisioning scripts | COMPLETE | SSH-based setup scripts |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Hetzner server purchase flow | MISSING | No API integration to create/list/delete VMs |
| Hetzner SSH key registration | MISSING | Can't register keys with Hetzner API |
| Hetzner server type/region selection UI | MISSING | No pricing or availability display |
| Domain purchase via registrar API | MISSING | No registrar integration |
| Cloudflare domain connection | MISSING | No zone import/creation |
| Cloudflare DNS record automation | MISSING | No A/AAAA/CNAME record creation |
| DNS propagation verification | MISSING | No dig/lookup checks |
| Caddy route wiring after deploy | MISSING | No Admin API client |
| End-to-end provisioning wizard | MISSING | No guided workflow UI |
| Server bootstrap after purchase | MISSING | No cloud-init or auto-SSH-and-provision flow |

### Key Files

- `app/models/server.rb` — Provider enum, region, IP storage
- `app/models/credential.rb` — Provider credentials (Hetzner, Cloudflare)
- `docs/plans/provisioning-hetzner.md` — Planning doc (unimplemented)
- `docs/plans/domains-dns.md` — Planning doc (unimplemented)

### Verdict

The data model is ready (servers have providers, credentials are stored). But zero API
integration exists. A user currently has to: manually buy a server on Hetzner, manually
set up DNS on Cloudflare, manually add the server to Conductor, then provision via scripts.
The vision is that all of this happens in Conductor with a few clicks.

### Priority Gaps

1. **Hetzner API client** — `HetznerClient` service: list server types, list regions, create server, delete server, register SSH key
2. **Cloudflare DNS API client** — `CloudflareClient` service: list zones, create zone, CRUD DNS records
3. **Server bootstrap flow** — After Hetzner creates VM: wait for IP, SSH in, run provision scripts automatically
4. **Domain wiring flow** — After DNS is set: create Caddy route, verify SSL, mark app as live
5. **Provisioning wizard UI** — Guided multi-step form: pick provider → pick plan → pick region → set domain → deploy

---

## Cross-Pillar Dependencies

```
Pillar 6 (Provisioning) ──→ Pillar 3 (Provider APIs) ──→ Pillar 2 (Caddy routing)
                                                      ──→ Pillar 1 (Kamal deploy)
                                                      ──→ Pillar 4 (Postgres setup)

Pillar 5 (Maintenance) ──→ All other pillars (monitors everything)
```

The critical path is: **Provisioning APIs → Caddy routing → live app → continuous operations**.
Without provider APIs, automation stops at manual setup. Without Caddy routing, apps are not reachable.
Without recurring operations, the product does not become a daily-use control plane.

---

## Overall Scorecard

| Pillar | Built | Partial | Missing | Health |
|---|---|---|---|---|
| 1. Kamal Docker | 5 | 0 | 6 | 45% |
| 2. Native Caddy | 1 | 2 | 6 | 22% |
| 3. Provider APIs | 1 | 2 | 8 | 18% |
| 4. Postgres Ops | 3 | 0 | 7 | 30% |
| 5. Server Maintenance | 3 | 2 | 7 | 33% |
| 6. One-Click Provisioning | 4 | 0 | 10 | 29% |

### What works today (ship-ready)

- Docker deploy (basic, not Kamal-native)
- Server provisioning via SSH scripts
- Backup pipeline to cloud storage
- Email alerts for critical failures
- Dashboard with current fleet status
- Credential management

### What's stubbed/partial (needs completion)

- Native systemd deployment (works but no routing)
- Server metrics (collection works, not scheduled)
- R2/S3 uploads (CLI over SSH, no SDK)

### What's missing entirely (needs building)

- Caddy Admin API client (the routing layer)
- Kamal CLI integration
- Hetzner API (server provisioning)
- Cloudflare DNS API (domain management)
- SES domain verification
- Postgres restore, monitoring, failover
- Drift detection, auto-updates, cert monitoring
- Multi-host orchestration
- Provisioning wizard UI

---

## Recommended Build Order

### Phase 1: Make the core loop work (Deploy → Route → Live)
1. `CaddyClient` service — Caddy Admin API integration
2. Recurring job scheduling — metrics, container sync, backups
3. Postgres restore from backup

### Phase 2: Provider APIs (Automate infrastructure)
4. `HetznerClient` service — server provisioning API
5. `CloudflareClient` service — DNS record management
6. Credential validation against provider APIs
7. Server bootstrap flow (purchase → provision → ready)

### Phase 3: Fleet operations (The moat)
8. Kamal and optional ONCE-compatible backend integration for Docker deploys
9. Multi-host deployment orchestration
10. Drift detection and auto-remediation
11. Server update automation
12. Historical metrics and trend analysis

### Phase 4: One-click UX (The product)
13. Provisioning wizard (server + domain + app in one flow)
14. Domain purchase/connection flow
15. Certificate monitoring and alerting
16. Webhook/Slack notifications
