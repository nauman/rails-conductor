# Sessions Index

Session logs capture implementation history, doc realignment, and the current handoff point for the next coding slice.

| File | Purpose |
| --- | --- |
| `docs/sessions/2026-03-12-production-readiness.md` | Database schema fixes, deploy streaming, and production-readiness cleanup |
| `docs/sessions/2026-03-28-routing-baseline-and-doc-realignment.md` | Records the recurring-ops baseline, shipped Caddy foundation, and refreshed docs state |
| `docs/sessions/2026-07-12-operational-dashboard-health.md` | Truthful app-health states, actionable incidents, repaired jobs frames, and responsive Overview verification |
| `docs/sessions/2026-08-07-backups-proven-by-restore.md` | Thirteen green schedules that had never uploaded anything, turned into backups proven by restore: credentials, per-app object keys, AWS CLI prerequisite, retention, and verification that gates the verdict |
| `docs/sessions/2026-09-05-stale-records-and-assigned-identity.md` | A deploy hold that turned into a fleet-wide audit of stored-but-never-refreshed state and names doing an identity's job — four adversarial review rounds, ADRs 0010–0013, and one security change deliberately reverted unshipped |
| `docs/sessions/2026-09-07-identity-secrets-and-the-shell.md` | Conductor installs its own SSH key instead of asking; credentials leave the command line; four adversarial rounds on shell commands that read correctly and behaved differently — twice weakening authorization |
