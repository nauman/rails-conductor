# SC-003: Restore a Database Backup

## User Story (Raw)

> "I have nightly Postgres backups going to R2. The day I actually need one, I want to restore it from Conductor and trust that it worked — not discover the dump was empty."

---

## Actors

| Actor | Description |
|-------|-------------|
| **Indie Developer** | Needs to recover an app's database. |
| **Backup** | A `pg_dump` artifact stored in S3/R2. |
| **Server / Database** | The Postgres instance receiving the restore. |
| **Conductor** | Runs and verifies the restore over SSH. |

---

## Goals

1. **Restore from a chosen backup** — pick a backup and restore it to a target database.
2. **Verify the result** — confirm the restore completed and the data is usable.
3. **Be safe** — never silently overwrite a live database without confirmation.

---

## Scenario Flow

### Scenario 3.1: Restore a backup

**Preconditions:**
- At least one completed backup exists for the app.
- Target database and credentials are known to Conductor.

**Flow:**
1. Developer opens the app's backups and selects one.
2. Developer chooses "Restore", picks the target database, and confirms a typed safety prompt.
3. Conductor downloads the artifact and runs the restore over SSH with streaming output.
4. On completion, Conductor runs verification checks (row counts / sentinel queries).
5. UI shows restore status and verification result.

**Acceptance Criteria:**
- [ ] Restore streams progress and surfaces errors (no silent failures).
- [ ] A confirmation step is required before overwriting an existing database.
- [ ] Verification result is recorded with the restore.

---

## Data Model Implications

```
Backup (1) ──→ (N) Restore
                    ├── target_database
                    ├── status (running | completed | failed)
                    ├── verified (bool)
                    └── log
```

## Technical Notes

- Builds on the existing backup pipeline (`pg_dump` → R2). Restore execution does **not** exist yet — see `docs/plans/postgres-restore.md` and `docs/plans/backups-r2.md`.
- Verification could compare row counts against the source snapshot or run app-defined sentinel queries.

## Open Questions

1. Restore in place vs. into a temporary database for verification before swap?
2. How are credentials for the target database supplied and scoped?
3. Point-in-time recovery — in scope or dump-only for now?

## Priority

**High** — backups are only trustworthy once restore is proven.
