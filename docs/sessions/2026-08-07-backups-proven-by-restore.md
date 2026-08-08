# Session: Backups Proven by Restore

**Date:** 2026-08-07
**Scope:** Fleet database backups end to end — credentials, object naming, prerequisites, retention, verification
**Goal:** Turn thirteen green schedules that protected nothing into backups proven by an actual restore

## The Starting Position

Thirteen backup schedules reported healthy. **None had ever uploaded anything.**
The bucket was empty. Four independent faults had to line up for that to be
invisible, and they did.

## What Shipped

| Commit | Change |
| --- | --- |
| `2b5af95` | Learning: `kamal app exec` needs `--reuse` — the bare form runs `<image>:latest` in a new throwaway container |
| `23f060a` | Guide: backup credentials — the R2 API-token vs S3 key-pair trap |
| `623d7c3` | Object keys namespaced by app; AWS CLI checked before the dump, not after |
| `d3718d6` | Retention enforcement; AWS CLI v2 installer fallback where apt cannot help |
| `be0b6c3` | Learning: a backup is a restore, not a file size |
| `9bd10bc` | A failed restore demotes `status`; host apps dumpable via an env file |
| `2f8e235` | An explicit env file beats the `<slug>-db` container name guess |

### The credential

All thirteen backups pointed at a Cloudflare **API token** with no secret at all,
producing `Partial credentials found in env, missing: AWS_SECRET_ACCESS_KEY`.
An existing credential was already an **account-wide R2 key pair** on the correct
account — previously recorded as bucket-scoped without being checked. Probed it
(`list` → `PUT` → `DELETE`), repointed everything, renamed it honestly.

**No new Cloudflare token was needed.** The prior session's ask was withdrawn.

### The collision

Object keys were `<bucket>_<timestamp>.sql.gz` — named after the DESTINATION.
Thirteen apps share one bucket, the stamp is second-resolution, and every daily
backup fires in the same minute. Two apps finishing together wrote the **same
key**, and R2 PUT is last-write-wins: one app's backup silently replaced
another's. Now `<slug>/<slug>_<timestamp>.sql.gz`, with the local dump path kept
flat.

### The prerequisite

R2 has no CLI; uploads go through `aws s3 cp --endpoint-url`. The CLI was checked
implicitly, by the upload, at the very end — so one box dumped and gzipped its
whole database every night before failing on `aws: command not found`. Worse,
**Ubuntu 24.04 ships no `awscli` package at all** (`Candidate: (none)`), so apt
could never satisfy it. Now: check first, apt where it works, then AWS's own v2
installer, arch-resolved. Proven unattended in production.

### The verdict

`verification_status` recorded the truth and gated nothing: one backup read
`completed` while its dump restored to **zero tables**. A restore that produces
no tables now demotes `status`, guarded so a stale dump cannot demote a backup
that has succeeded since.

### The host app

One app is a Hatchbox deployment — systemd + puma on `127.0.0.1:9020`, database
in host postgres — which Conductor could not back up at all: no container to
exec, no `DATABASE_URL` in a non-interactive SSH session. It instead matched an
abandoned, empty `<slug>-db` container left by a half-finished migration and
reported the empty dump as success. Backups now take an optional env file to
source, and that explicit configuration **beats** the container name heuristic.

## Verification

- **11 of 12 backups verified by actual restore** into a throwaway postgres,
  reporting table and row counts — not a status flag.
- Largest: 108 MB. Smallest real one: 16 tables, ~12 rows.
- Suite: 872 runs, 2,784 assertions, 0 failures (one pre-existing unrelated
  failure in `dedicated_db_provisioner_test.rb:71`, confirmed present without
  these changes).

The single exception is an app with `status: stopped` and no container — an
honest failure that can no longer masquerade as anything else.

## What This Cost, and the Lesson

Every defect found this session was found by **checking production**, never by
tests passing. Two were self-inflicted by verifying a mechanism instead of the
thing it was supposed to guarantee:

- a guard that checked the label on the door instead of where the door led;
- a precedence rule written one hour and reversed the next, because the
  heuristic it trusted was exactly the one that had already lied.

Restore verification also found an **8-day application outage** that fleet
monitoring did not — an app writing nothing looks identical to an app that is
not running.

## Open for a Human

- Two legacy databases on a host postgres with no owner and no backup —
  43 tables / 326k lifetime writes, and 25 tables. Archive or delete is a
  judgement call about data that cannot be attributed.
- One app is `stopped` with no container; its backup cannot succeed. Delete the
  backup or deploy the app.
- One Cloudflare credential returns `Invalid request headers` on live API calls
  while the UI looks healthy, because the zone list is cached locally.
- Retention now prunes, but the newest object is never deleted regardless of
  age — deliberately. Revisit if that is not the wanted policy.

## Related

- `docs/learnings/a-backup-is-a-restore.md`
- `docs/learnings/kamal-app-exec-reuse.md`
- `docs/learnings/operate-as-deploy-not-root.md`
- `docs/guides/backup-credentials.md`
