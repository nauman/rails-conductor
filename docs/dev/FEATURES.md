# Features

This is a compact feature snapshot. For the full capability map, use `docs/plans/INDEX.md`.

## Shipped Foundation

- [x] Server management with provider, region, and SSH key association
- [x] Encrypted SSH key and credential storage
- [x] SSH command execution with streaming output
- [x] Provisioning script system with built-in server/app scripts
- [x] Basic Docker deployment pipeline over SSH
- [x] Deployment log streaming via ActionCable
- [x] Server metrics collection
- [x] Managed container status sync, logs, and restart actions
- [x] Database backups to S3/R2-compatible storage
- [x] Dashboard issue detection and fleet summary
- [x] API token authentication and external API surface
- [x] Recurring ops baseline for metrics refresh, container sync, and scheduled backups
- [x] SSH-backed Caddy route management for managed add/remove domain tooling

## Partial Capabilities

- [ ] Native Puma/systemd deployment without full routing
- [ ] Cloudflare and full domain lifecycle flows without provider API automation
- [ ] R2 backup uploads without full bucket-management workflows
- [ ] Monitoring data with recurring freshness but without trend history or recurring-failure surfacing
- [ ] Caddy routing without route persistence, deploy hooks, reconciliation, or certificate lifecycle
- [ ] Log visibility without runtime log storage or deeper filtering
- [ ] Server bootstrap and provider provisioning without full end-to-end automation
- [ ] Postgres recovery planning without shipped restore execution

## Deferred or Descoped

- [ ] Managed-app Active Storage introspection and blob cleanup
- [ ] Portainer integration or deep Docker inventory UI
- [ ] Kamal as a runtime backend beyond an assessment document

## Next Major Capabilities

- [ ] Caddy route management and certificate lifecycle
- [ ] Hetzner provisioning from the control panel
- [ ] Cloudflare DNS record automation
- [ ] Postgres restore and backup verification
- [ ] Continuous maintenance with drift detection and update workflows
- [ ] Native deploy completion and multi-app routing
