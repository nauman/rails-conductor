# A backup is a restore — size is not evidence

**Found:** 2026-08-07 · **Trigger:** the fleet's first end-to-end backup run
· **Status:** verification shipped; automatic gating still a gap

## What happened

The first run where all thirteen backups actually reached the bucket produced
ten "completed" rows. Three of those completed dumps were **1 KB, 2 KB and
4.7 KB**. `MIN_DUMP_BYTES` is 200, so all three sailed through.

Restoring them told a different story:

| App | Dump | Restore |
|---|---|---|
| Starrrs | 4.7 KB | **verified** — 16 tables, ~12 rows (a genuinely small app) |
| minimalnarrow | 2.1 KB | **verified** |
| intellectaco | 1.0 KB | **failed — restore produced no tables** |

Only the restore separated "small" from "empty". No byte threshold could have:
a real 4.7 KB backup and a worthless 1 KB one are the same kind of number.

## The rule

**A backup is not a file, it is a successful restore.** Everything short of
that — exit code, file size, gzip integrity, the object being present in the
bucket — is a *necessary* check that still cannot tell you the dump contains
your data. Each of those checks was added after it failed to catch something,
and each one was still not enough.

Report the evidence in those terms. "Backed up ✅" invites trust; "restored into
a clean postgres: 44 tables, ~27,360 rows" *is* the trust.

## The intellectaco case, in full

The empty dump was **not a backup bug**. The database really was empty:

- `intellecta_production` — 0 tables in `public`
- `intellectaco-web` — `Exited (137)` for **8 days** (137 = SIGKILL/OOM)

The app had been dead for over a week and its database had nothing in it. The
backup faithfully dumped an empty database, and the restore verification is what
surfaced it. The backup system was working; it was reporting on a broken app.

Worth sitting with: **backup verification found an 8-day outage that fleet
monitoring did not.** A verifier that restores real data is also a liveness
check, because an app that is not writing anything looks identical to an app
that is not running.

## Still open

`verification_status` is recorded but does not gate anything. A backup whose
restore produced no tables still reads `completed`. It should not — a dump that
cannot restore is a failure, and the row that says otherwise is the same class
of lie as the upload that recorded success without uploading.

## Related

- `app/services/backup_restore_verifier.rb` — restores into a throwaway
  postgres container and counts tables/rows.
- `docs/guides/backup-credentials.md` — the operator-facing version.
