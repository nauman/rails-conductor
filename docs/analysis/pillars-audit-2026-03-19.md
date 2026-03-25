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

---

## Pillar 1: Fleet Control

Fleet control is about visibility. One place to see servers, apps, deployments, issues, and
operational state across the entire fleet.

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Server CRUD with provider/region | COMPLETE | Full model with SSH key association |
| App CRUD with deploy method | COMPLETE | Docker and native deploy methods |
| Deployment lifecycle tracking | COMPLETE | pending → building → deploying → succeeded/failed |
| Dashboard with fleet summary | COMPLETE | Server counts, app counts, issue aggregation |
| Issue detection | COMPLETE | Offline servers, high CPU/disk, failed deploys/backups |
| Server metrics collection | PARTIAL | CPU/RAM/disk via SSH — works but not on recurring schedule |
| Container status sync | PARTIAL | `docker inspect` polling — works but not scheduled |
| API token authentication | COMPLETE | External API surface with token auth |
| Real-time streaming | COMPLETE | ActionCable for deploy logs, script output |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Recurring metrics schedule | MISSING | `recurring.yml` has only 1 job (queue cleanup) |
| Native app status checks | MISSING | No `systemctl status` polling for systemd services |
| Historical metrics storage | MISSING | Snapshots only, no time-series table |
| Dashboard widgets/scheduling | MISSING | No auto-refresh, no widget framework |
| Request/performance metrics | MISSING | No response times, error rates, throughput |

### Key Files

- `app/controllers/dashboard_controller.rb` — Issue aggregation and fleet stats
- `app/services/server_metrics.rb` — CPU, memory, disk collection via SSH
- `app/services/container_status.rb` — Docker inspect parsing
- `app/jobs/refresh_server_metrics_job.rb` — Metrics job (not scheduled)
- `app/jobs/sync_container_status_job.rb` — Container polling (not scheduled)
- `app/models/server.rb` — Server model with provider, status, metrics
- `app/models/app.rb` — App model with deploy method, container tracking

### Verdict

The fleet dashboard works and shows real data. The gap is that metrics and container status are
not on a recurring schedule, so the data goes stale unless manually refreshed. Adding recurring
jobs to `recurring.yml` is the lowest-effort, highest-impact fix across all pillars.

### Plan Coverage

| Plan | Status | Gap |
|---|---|---|
| `conductor-phase-0-1.md` | Implemented | — |
| `conductor-phase-2-ssh.md` | Implemented | — |
| `monitoring-ops.md` | Implemented | Recurring schedule, trends, advanced alerts |
| `sc-001-kamal-monitoring.md` | Partial | Dashboard widgets, scheduling |
| `portainer-docker.md` | Deferred | Core Docker operations already exist; remaining scope is optional hygiene |
| `logs-observability.md` | Partial | Log storage, filtering, analytics |

### Missing Plans

- **Recurring job infrastructure** — No plan defines what jobs run, how often, failure handling. Every pillar depends on this.
- **Historical metrics** — No plan for time-series storage, trend analysis, or capacity forecasting.
- **Notification channels** — No plan for Slack, webhooks, or PagerDuty beyond email.

---

## Pillar 2: Runtime Backends

Runtime backends are the execution layer. Conductor should support multiple ways to deploy and
run apps: Kamal Docker, native Puma/systemd, and optionally ONCE-compatible workflows.

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Docker deploy (build + run) | COMPLETE | `AppDeployer` — clone, build, run via SSH |
| Native/systemd deploy | PARTIAL | `NativeDeployer` — scripts work, but no Caddy wiring |
| Deploy method routing | COMPLETE | `DeployAppJob` routes to Docker or native deployer |
| Health checks | COMPLETE | Configurable path, retries, timeout |
| Container start/stop/restart | COMPLETE | Docker commands and systemd commands |
| Deployment log streaming | COMPLETE | ActionCable real-time broadcast |
| Environment variable injection | COMPLETE | Encrypted, per-app, Docker `-e` and script export |
| 5 built-in provisioning scripts | COMPLETE | server-provision, ruby-install, app-setup, app-deploy, systemd-setup |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Kamal CLI integration | MISSING | Gem installed but unused — deploys use raw Docker |
| Kamal config generation | MISSING | No dynamic `deploy.yml` per managed app |
| Registry push/pull | MISSING | Build-only, no remote registry support |
| Rollback | MISSING | No image/release history tracking |
| Multi-host rolling deploys | MISSING | Each app tied to single server |
| Blue-green / canary | MISSING | No versioned deployment strategies |
| ONCE-compatible packaging | MISSING | No `/up` + `/storage` + hooks standardization |
| Native app Caddy registration | MISSING | systemd-setup doesn't wire Caddy route |
| Puma config generation | MISSING | No `puma.rb` template for native apps |

### Key Files

- `app/services/app_deployer.rb` — Docker deployment (179 lines, complete)
- `app/services/native_deployer.rb` — Native deployment (131 lines, partial)
- `app/jobs/deploy_app_job.rb` — Routes to appropriate deployer
- `app/models/deployment.rb` — Status states, timing, log tracking
- `app/channels/deploy_channel.rb` — Real-time streaming
- `app/models/env_variable.rb` — Encrypted env vars with Docker format
- `db/seeds.rb` — 5 built-in provisioning scripts (lines 152–392)

### Verdict

Docker deploy works end-to-end but uses raw `docker build && docker run`, not Kamal. Native
deploy works for Puma/systemd but stops at the service boundary — traffic can't reach the app
because Caddy routing isn't wired. The Kamal integration that would add rolling deploys,
registry support, and rollback is entirely unbuilt.

### Plan Coverage

| Plan | Status | Gap |
|---|---|---|
| `conductor-phase-3-deployment.md` | Implemented | Basic Docker deploy only |
| `deployment-kamal.md` | Stale | Superseded by SSH+Docker approach; needs revisit |

### Missing Plans

- **Native deploy completion** — No plan covers wiring systemd-setup to Caddy, puma.rb generation, or socket-based routing.
- **Release versioning and rollback** — No plan for tracking image/release history or rolling back.
- **Multi-host orchestration** — No plan for coordinating deploys across multiple servers.
- **ONCE-compatible backend** — No plan for how to use ONCE CLI as an execution backend on managed servers.

---

## Pillar 3: Routing and Edge

Routing and edge is about making apps reachable. Caddy orchestration, domain management,
certificates, and traffic state across the fleet.

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Caddy installation | COMPLETE | In server-provision script |
| App domain field | COMPLETE | Stored in database per app |
| SSL enabled flag | COMPLETE | Per-app boolean, used in URL helper |
| Server caddy_port field | COMPLETE | Schema tracks Caddy admin port per server |
| Add/remove domain tools | PARTIAL | AI tools exist but are stubs — no actual API calls |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Caddy Admin API client | MISSING | Zero implementation |
| Route CRUD | MISSING | Can't add/remove/list routes at runtime |
| Route sync/reconciliation | MISSING | No desired-state vs actual-state comparison |
| Dynamic route management | MISSING | Domains stored but don't route traffic |
| SSL/TLS certificate lifecycle | MISSING | No cert provisioning, expiry tracking, or renewal |
| Multi-app routing on one server | MISSING | Schema supports it, Caddy not configured |
| Port allocation | MISSING | Manual port assignment, no conflict detection |
| Route drift detection | MISSING | No comparison of DB state vs Caddy config |
| Certificate status queries | MISSING | Can't ask Caddy about cert state |

### Key Files

- `app/tools/add_domain_tool.rb` — STUBBED (43 lines, returns fake success)
- `app/tools/remove_domain_tool.rb` — STUBBED (35 lines, returns fake success)
- `app/models/app.rb` — `domain`, `ssl_enabled`, `port` fields
- `app/models/server.rb` — `caddy_port` field
- `caddy_ops_ui_architecture.md` — Architecture vision (unimplemented)
- `docs/plans/routing-caddy.md` — Plan (partial)

### Verdict

This is the single biggest gap in the system. Apps can be deployed but traffic can't reach
them because there is no Caddy Admin API client. The `CaddyClient` service is the #1 build
priority across all pillars. Everything downstream — native multi-app hosting, domain
automation, certificate management — depends on this existing.

### Plan Coverage

| Plan | Status | Gap |
|---|---|---|
| `routing-caddy.md` | Partial | Vision exists; entire API client, sync job, and cert lifecycle unbuilt |
| `domains-dns.md` | Partial | Domain schema exists; DNS CRUD, validation, alerts unbuilt |

### Missing Plans

- **CaddyClient service spec** — `routing-caddy.md` describes the vision but doesn't spec the service: HTTP client, route data model, error handling, retry logic, SSH tunnel strategy.
- **Certificate lifecycle** — No plan for cert expiry monitoring, renewal automation, manual cert upload, or Caddy auto-HTTPS coordination.
- **Port allocation** — No plan for auto-assigning ports to native apps or detecting conflicts on shared servers.

---

## Pillar 4: Provisioning and Provider Automation

This pillar is about making infrastructure setup happen from Conductor instead of requiring
manual work on provider dashboards. Buy servers, connect domains, configure storage and email.

### What's Built

| Provider | Capability | Status | Detail |
|---|---|---|---|
| Generic | Credential storage | COMPLETE | Encrypted, full CRUD, provider-typed |
| Generic | Provisioning scripts | COMPLETE | SSH-based execution with streaming output |
| AWS SES | SMTP email sending | PARTIAL | SMTP configured, mailers work |
| Cloudflare R2 | Backup uploads | PARTIAL | S3-compatible CLI via SSH |
| All | Provider enum in models | COMPLETE | Server and Credential models track provider type |

### What's Missing

| Provider | Capability | Status | Detail |
|---|---|---|---|
| Hetzner | Server creation API | MISSING | No API client |
| Hetzner | Server type/region listing | MISSING | No pricing or availability |
| Hetzner | SSH key registration | MISSING | Can't register keys via API |
| Hetzner | Server deletion | MISSING | No lifecycle management |
| Cloudflare DNS | Zone management | MISSING | No API client |
| Cloudflare DNS | Record CRUD | MISSING | No A/AAAA/CNAME automation |
| Cloudflare DNS | Propagation verification | MISSING | No dig/lookup checks |
| Cloudflare R2 | Bucket management | MISSING | No listing, creation, validation |
| AWS SES | Domain verification | MISSING | No SES API calls |
| AWS SES | Bounce/complaint handling | MISSING | No feedback loop |
| All | Credential validation | MISSING | Keys saved but never tested against API |
| All | Server bootstrap flow | MISSING | No post-creation automation (wait IP → SSH → provision) |

### Key Files

- `app/models/credential.rb` — Encrypted credentials with provider enum
- `app/models/server.rb` — Provider, region, IP, caddy_port
- `app/services/database_backup.rb` — R2/S3 upload methods (CLI over SSH)
- `app/services/provisioning_service.rb` — Script execution on servers
- `app/mailers/alert_mailer.rb` — SES-backed email delivery
- `config/environments/production.rb` — SES SMTP config (lines 63–73)
- `Gemfile` — `aws-sdk-ses`, `aws-sdk-s3` gems installed but SDK not used directly

### Verdict

Credentials are stored securely and provisioning scripts run over SSH. Beyond that, all
provider integrations are either stubs or CLI workarounds. No direct SDK usage exists for
any provider. The gap is that a user must manually create servers on Hetzner, set up DNS on
Cloudflare, and configure SES — then tell Conductor about it. The vision is that Conductor
does all of this.

### Plan Coverage

| Plan | Status | Gap |
|---|---|---|
| `cloudflare.md` | Partial | Credential storage works; API calls, validation missing |
| `provisioning-hetzner.md` | Stale | Never started |
| `ssh-keys.md` | Partial | Key storage works; Hetzner registration missing |
| `domains-dns.md` | Partial | Schema works; DNS CRUD missing |

### Missing Plans

- **Server bootstrap flow** — No plan for the post-creation sequence: Hetzner creates VM → wait for IP → SSH in → run provision scripts → verify ready → register in Conductor.
- **Credential validation** — No plan for testing API keys against provider APIs before saving.
- **Provisioning wizard** — No plan for the guided UI flow: pick provider → pick plan → pick region → set domain → deploy.

---

## Pillar 5: Data and Backups

Postgres backup, restore, monitoring, and cluster lifecycle. This is about making databases
operationally trustworthy, not just backed up.

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Backup creation (pg_dump) | COMPLETE | Compressed, uploaded to cloud storage |
| Backup scheduling | COMPLETE | hourly/daily/weekly/monthly via Solid Queue |
| Multiple storage providers | COMPLETE | Cloudflare R2, AWS S3, Backblaze B2, local |
| Backup status tracking | COMPLETE | pending, running, completed, failed, warning |
| Retention configuration | COMPLETE | Configurable retention days per backup |
| Backup failure email alerts | COMPLETE | AlertMailer to admin users |
| Backup CRUD and UI | COMPLETE | Web interface and API endpoints |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Restore (pg_restore) | MISSING | Zero restore functionality |
| Download backup from cloud | MISSING | Can't retrieve stored backups |
| Backup verification | MISSING | No integrity checks or test restores |
| Restore drills | MISSING | No automated recovery testing |
| Backup encryption | MISSING | Open question in backups-r2.md, unanswered |
| Cluster creation | MISSING | Generic script framework only |
| Replication setup | MISSING | No replica configuration |
| Failover management | MISSING | No promotion or switchover logic |
| DB health monitoring | MISSING | No pg_isready, connection counts, query stats |
| Version upgrades | MISSING | No Postgres version management |
| Connection pool monitoring | MISSING | No visibility into pool usage |

### Key Files

- `app/services/database_backup.rb` — pg_dump + R2/S3 upload
- `app/jobs/backup_job.rb` — Backup execution
- `app/jobs/run_scheduled_backups_job.rb` — Scheduled backup runner
- `app/models/backup.rb` — Backup model with scheduling, retention, status
- `app/controllers/backups_controller.rb` — Web CRUD
- `app/controllers/api/v1/backups_controller.rb` — API endpoints
- `app/mailers/alert_mailer.rb` — Failure notifications

### Verdict

The backup creation pipeline is solid and production-ready. Scheduling, multi-provider
upload, failure alerting, and retention tracking all work. But you can back up and never
restore — that's half the value. Restore, verification, and database health monitoring are
the priority gaps. Cluster lifecycle features (replication, failover, upgrades) are longer-term.

### Plan Coverage

| Plan | Status | Gap |
|---|---|---|
| `backups-r2.md` | Partial | Backup works; restore, verification, encryption missing |
| `data-layer.md` | Stale | Over-scoped; no lightweight Postgres ops replacement |
| `active-storage.md` | Deferred | Per-app blob visibility requires invasive integration and cleanup is out of scope |

### Missing Plans

- **Postgres restore** — No plan for downloading from cloud, running pg_restore, verifying integrity, or restore drills. This is the single most important gap in this pillar.
- **Database health monitoring** — No plan for pg_isready checks, connection pool visibility, slow query detection, or replication lag.
- **Backup encryption** — `backups-r2.md` asks the question but no plan answers it.

---

## Pillar 6: Continuous Maintenance

Always-on operations: recurring checks, server updates, drift detection, certificate monitoring,
and alerting. This is what makes Conductor a daily-use product, not just a deploy-time tool.

### What's Built

| Capability | Status | Detail |
|---|---|---|
| Backup failure email alerts | COMPLETE | End-to-end with HTML template |
| Server offline email alerts | COMPLETE | End-to-end with affected apps listed |
| Deployment failure email alerts | COMPLETE | End-to-end with log excerpt |
| Dashboard issue aggregation | PARTIAL | Detects offline, high CPU/disk, failed deploys/backups |
| Server metrics collection | PARTIAL | Works via SSH but not on recurring schedule |
| Container status polling | PARTIAL | Works via SSH but not on recurring schedule |
| Solid Queue framework | COMPLETE | Database-backed job runner with Puma plugin |

### What's Missing

| Capability | Status | Detail |
|---|---|---|
| Recurring job scheduling | PARTIAL | Only 1 job in `recurring.yml` (queue cleanup) |
| Auto security updates | MISSING | No unattended-upgrades automation |
| Drift detection | MISSING | Mentioned in docs, zero implementation |
| Certificate expiry monitoring | MISSING | No cert tracking or expiry alerts |
| Disk pressure email alerting | MISSING | Detected on dashboard but no notification sent |
| Historical metrics / trends | MISSING | Point-in-time snapshots only |
| Slack/webhook notifications | MISSING | Email only |
| Alert deduplication | MISSING | Could spam on repeated failures |
| Maintenance windows | MISSING | No scheduled downtime support |

### Key Files

- `app/mailers/alert_mailer.rb` — 3 alert methods (backup, server, deploy)
- `app/views/alert_mailer/` — HTML email templates
- `config/recurring.yml` — Only `clear_solid_queue_finished_jobs` configured
- `app/jobs/refresh_server_metrics_job.rb` — Exists but not scheduled
- `app/jobs/sync_container_status_job.rb` — Exists but not scheduled
- `app/jobs/run_scheduled_backups_job.rb` — Exists but not scheduled
- `app/controllers/dashboard_controller.rb` — `collect_issues` method

### Verdict

Email alerts for the three critical failure paths (backup, server offline, deploy) work
end-to-end. The dashboard aggregates issues with severity levels. But the system doesn't
run on its own — the recurring jobs that would make it a continuous monitoring product are
not configured. This is the cheapest fix with the most impact: adding 3–4 entries to
`recurring.yml` makes metrics, container sync, and backup scheduling automatic.

### Plan Coverage

| Plan | Status | Gap |
|---|---|---|
| `monitoring-ops.md` | Implemented | Basic dashboard done; recurring, trends, and advanced alerts missing |
| `logs-observability.md` | Partial | Basic log access; storage, filtering, analytics missing |

### Missing Plans

- **Recurring ops schedule** — No plan defines what jobs run, at what interval, with what failure handling. Needs: metrics refresh (5 min), container sync (2 min), backup scheduler (1 min), server health check (5 min).
- **Drift detection** — No plan for comparing expected state (DB) vs actual state (server). Needs: Caddy route drift, package version drift, service status drift, file permission drift.
- **Auto security updates** — No plan for setting up unattended-upgrades, tracking update status, or scheduling maintenance windows.
- **Certificate monitoring** — No plan for tracking cert expiry dates, alerting before expiry, or coordinating with Caddy auto-HTTPS.
- **Notification channels** — No plan for Slack, webhook, or PagerDuty integrations beyond email.

---

## Cross-Pillar Dependencies

```
Pillar 4 (Provisioning) ──→ Pillar 3 (Routing) ──→ Pillar 2 (Runtime backends)
                         ──→ Pillar 5 (Data)    ──→ Pillar 2 (Runtime backends)

Pillar 6 (Maintenance)  ──→ All pillars (monitors everything)

Pillar 1 (Fleet control) ←── All pillars (displays everything)
```

The critical path is: **Provider APIs → Caddy routing → live app → continuous operations**.

Without provider APIs, automation stops at manual setup. Without Caddy routing, apps are
not reachable. Without recurring operations, the product does not become a daily-use
control plane.

---

## Overall Scorecard

| Pillar | Built | Partial | Missing | Health |
|---|---|---|---|---|
| 1. Fleet Control | 7 | 2 | 5 | 64% |
| 2. Runtime Backends | 8 | 1 | 9 | 47% |
| 3. Routing and Edge | 3 | 2 | 9 | 29% |
| 4. Provider Automation | 5 | 2 | 12 | 32% |
| 5. Data and Backups | 7 | 0 | 11 | 39% |
| 6. Continuous Maintenance | 4 | 3 | 9 | 38% |

### What works today (ship-ready)

- Server and app CRUD with encrypted credentials
- Docker deploy over SSH with streaming logs
- 5 built-in provisioning scripts
- Backup creation and scheduling to S3/R2
- Email alerts for backup failures, server offline, deploy failures
- Dashboard with fleet status, issue detection, server metrics
- API token auth and external API surface

### What's stubbed/partial (needs completion)

- Native Puma/systemd deployment (works but no Caddy routing)
- Server metrics collection (works but not on recurring schedule)
- Container status sync (works but not scheduled)
- R2/S3 backup uploads (CLI over SSH, no SDK)
- Domain tools (AI tool stubs, no actual API calls)

### What's missing entirely (needs building)

- Caddy Admin API client (the routing layer — #1 priority)
- Recurring job scheduling in `recurring.yml`
- Postgres restore from cloud backup
- Hetzner API client (server provisioning)
- Cloudflare DNS API client (domain management)
- SES domain verification
- Server bootstrap flow (post-creation automation)
- Drift detection and auto-remediation
- Auto security updates
- Certificate lifecycle management
- Historical metrics and trend analysis
- Multi-host deployment orchestration
- Release versioning and rollback
- Notification channels beyond email

---

## Plan Gap Summary

Capabilities that need plans but don't have one:

| Missing Plan | Pillar | Why It Matters |
|---|---|---|
| Recurring ops schedule | 1, 6 | Every pillar assumes jobs run automatically — none are scheduled |
| CaddyClient service spec | 3 | routing-caddy.md has vision but no service-level spec |
| Postgres restore | 5 | Backup without restore is a liability |
| Server bootstrap flow | 4 | Post-creation automation doesn't exist |
| Certificate lifecycle | 3 | No cert tracking, expiry alerts, or renewal coordination |
| Port allocation | 3 | Native multi-app hosting needs auto-port assignment |
| Release versioning/rollback | 2 | No image history, no way to roll back |
| Multi-host orchestration | 2 | Each app locked to one server, no fleet-wide operations |
| Drift detection | 6 | Mentioned everywhere, planned nowhere |
| Notification channels | 6 | Email-only limits daily-use value |
| Credential validation | 4 | Keys saved but never tested against provider APIs |
| Native deploy completion | 2 | No plan for Caddy wiring, puma.rb generation, socket routing |
| Backup encryption | 5 | Open question since backups-r2.md, never answered |

### Existing plans with unanswered blocking questions

| Plan | Open Question | Blocks |
|---|---|---|
| `deployment-kamal.md` | GitHub Actions vs local build runner? | CI/CD integration |
| `deployment-kamal.md` | Rolling vs blue/green deploys? | Multi-host deploy design |
| `cloudflare.md` | Token per zone vs account-wide? | Credential validation |
| `data-layer.md` | Shared cluster vs dedicated containers? | Postgres provisioning |
| `portainer-docker.md` | Portainer API vs custom agent? | Container management approach |
| `logs-observability.md` | DB vs object storage for logs? | Log persistence |
| `domains-dns.md` | Wildcard cert flow by default? | Certificate automation |
| `backups-r2.md` | Encrypt backups before upload? | Backup security |

### Plans that overlap without clear boundaries

| Plans | Overlap | Suggested Resolution |
|---|---|---|
| `cloudflare.md` + `domains-dns.md` | Both cover DNS records | cloudflare.md = provider client; domains-dns.md = domain lifecycle |
| `deployment-kamal.md` + `conductor-phase-3-deployment.md` | Phase 3 shipped SSH+Docker; Kamal plan is stale | Mark deployment-kamal.md as superseded or rewrite for Kamal-as-backend |
| `data-layer.md` + `backups-r2.md` | data-layer over-scoped and deferred; backup plan active | Replace data-layer.md with focused postgres-ops.md |
| `monitoring-ops.md` + `sc-001-kamal-monitoring.md` | Both cover dashboard monitoring | monitoring-ops.md = system; sc-001 = specific scenario |

---

## Recommended Build Order

Aligned with `docs/plans/INDEX.md` and `docs/VISION.md` Phase 1–4.

### Phase 1: Make the core loop work (Deploy → Route → Live)
1. **Recurring job scheduling** — Add metrics, container sync, and backup scheduler to `recurring.yml`
2. **CaddyClient service** — HTTP client for Caddy Admin API with route CRUD and sync
3. **Postgres restore** — Download from R2/S3, run pg_restore, verify integrity

### Phase 2: Automate infrastructure (Provider APIs)
4. **HetznerClient service** — List types/regions, create/delete servers, register SSH keys
5. **CloudflareClient service** — List zones, CRUD DNS records, verify propagation
6. **Server bootstrap flow** — Post-creation: wait for IP → SSH → provision → verify → register
7. **Credential validation** — Test API keys against provider endpoints before saving

### Phase 3: Build the fleet moat (Operations)
8. **Kamal backend integration** — Use Kamal CLI for richer Docker lifecycle, or ONCE where it fits
9. **Multi-host orchestration** — Fleet-wide deploys, rolling restarts, coordinated operations
10. **Drift detection** — Compare desired state (DB) vs actual state (server) with alerting
11. **Server update automation** — Unattended-upgrades setup, maintenance windows
12. **Historical metrics** — Time-series table, trend analysis, capacity forecasting

### Phase 4: One-click product UX
13. **Provisioning wizard** — Server + domain + app in one guided flow
14. **Certificate monitoring** — Expiry tracking, renewal alerts, Caddy coordination
15. **Webhook/Slack notifications** — Beyond email alerts
16. **AI orchestration layer** — Natural language workflows on top of the control plane
