---
title: Pull a database
description: Dump a remote PostgreSQL database over SSH, download it to the Conductor host, and optionally restore it into a local database.
order: 5
---

# Pull a database

A **database pull** runs `pg_dump` on one of your servers over SSH, downloads the
dump to the Conductor host via SCP, and (optionally) restores it into a local
PostgreSQL database. It's the reproducible version of the manual
`ssh … pg_dump | scp | pg_restore` dance.

## Start a pull

Go to **Pulls → New pull** and fill in:

| Field | Meaning |
|---|---|
| **Source server** | A server with SSH access configured (an SSH key + IP). |
| **Env file to source** | Optional. A file sourced before `pg_dump` so `$DATABASE_URL` is set. Hatchbox boxes keep it at `/home/deploy/<app>/.asdf-vars`. Leave blank if the variable is already in the shell environment. |
| **DATABASE_URL variable** | The env var holding the connection string (default `DATABASE_URL`). |
| **Source label** | Optional, display-only name for the pulls list. |
| **Restore into local database** | Optional. If set, Conductor **drops and recreates** that local database on its own host, then `pg_restore`s into it. Leave blank to only download the dump. |

The pull runs as a background job; its page streams live output over ActionCable.

## What it does

```
DatabasePull → DatabasePullJob → DatabasePullService
                                    │
        1. ssh: pg_dump -Fc --no-owner --no-acl "$DATABASE_URL" -f /tmp/…dump
        2. scp: download to <conductor>/tmp/dumps/
        3. ssh: rm the remote temp dump
        4. (optional) dropdb / createdb / pg_restore  → local restore_target
```

The dump uses the **source box's** `pg_dump`, so its client version matches the
remote server (avoids the "client older than server" failure when restoring
elsewhere). Custom format (`-Fc`) with `--no-owner --no-acl` keeps the dump
portable across roles.

## Notes & cautions

- **Restore is destructive.** A `restore_target` is dropped and recreated before
  restore — only set it for a throwaway/dev database.
- The Conductor host needs the PostgreSQL client tools (`pg_dump` on the remote,
  `pg_restore`/`createdb`/`dropdb` locally) for the restore step.
- `pg_restore` may exit non-zero on benign warnings (e.g. missing roles); that's
  logged but not treated as a failure. `dropdb`/`createdb` failures are fatal.
- Dumps are saved under `tmp/dumps/` on the Conductor host; the path is shown on
  the pull's page.
