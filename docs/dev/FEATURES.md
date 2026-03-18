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
- [x] Database backups to S3/R2-compatible storage
- [x] Dashboard issue detection and fleet summary
- [x] API token authentication and external API surface

## Partial Capabilities

- [ ] Native Puma/systemd deployment without full routing
- [ ] Cloudflare and domain flows without working API automation
- [ ] R2 backup uploads without full bucket-management workflows
- [ ] Monitoring data without complete scheduling and trend history
- [ ] Log visibility without storage, filtering, and analytics

## Next Major Capabilities

- [ ] Caddy route management and certificate lifecycle
- [ ] Hetzner provisioning from the control panel
- [ ] Cloudflare DNS record automation
- [ ] Postgres restore and backup verification
- [ ] Continuous maintenance with drift detection and update workflows
- [ ] Richer runtime backend support for Kamal and ONCE-compatible flows
