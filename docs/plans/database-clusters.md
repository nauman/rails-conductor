# Database Clusters Plan

## Pillar
Data and backups

## Status
Active — building (slice 1).

## Current Reality

- Apps on a shared host use one Postgres cluster with a database + role per app.
- Today this is **manual**: SSH in and `CREATE ROLE … CREATEDB` + `CREATE DATABASE … OWNER …`, then hand the password to the app's deploy config (see `docs/learnings/multi-app-hosting.md`).
- Conductor already executes on servers over SSH (`SshConnection`) and has a service-over-SSH pattern (`CaddyClient`).

## Goal

Hatchbox-style Postgres management: register a Postgres **cluster** running on a server, then **create and drop per-app databases** (database + role + generated password) from Conductor — no manual `psql`.

## Scope

- `DatabaseCluster` — a Postgres instance on a server (container name, admin role/password, port).
- `Database` — a database + role + credentials on a cluster, optionally tied to an app.
- `PostgresClusterClient` — runs admin SQL on the cluster via `SshConnection` + `docker exec … psql` (mirrors `CaddyClient`).
- Operations: create database (role + db + `CREATEDB`), drop database (db + role).
- Everything org-scoped (`current_organization`), credentials encrypted.
- UI: list databases on a cluster, create/drop.

## Non-goals

- Managing Postgres itself (install/upgrade/replication) — that's provisioning.
- Restore/backup (separate plans: `backups-r2.md`, `postgres-restore.md`).
- Non-Postgres engines.

## Core Workflows

1. **Register a cluster** — point Conductor at a Postgres running on a server (container name + admin creds).
2. **Create a database** — generate a role + database + password on the cluster; surface the connection details for the app's deploy config.
3. **Drop a database** — remove the database and role (guarded).

## Data Model

```
DatabaseCluster
 ├── organization, server
 ├── name, container_name (e.g. "conductor-postgres")
 ├── admin_username, admin_password (encrypted), port
 └── has_many :databases

Database
 ├── organization, database_cluster, app (optional)
 ├── name (e.g. "wiseherds_production")
 ├── username, password (encrypted)
 └── status (pending | active | error)
```

## Verification (test-first)

- `PostgresClusterClient#create_database` issues `CREATE ROLE … LOGIN PASSWORD … CREATEDB` then `CREATE DATABASE … OWNER …` (tested with a fake SSH connection, like `CaddyClientTest`).
- `#drop_database` issues `DROP DATABASE` then `DROP ROLE`.
- Model: `DatabaseCluster#provision_database!(name:)` creates a `Database` with a generated password and is org-scoped.
- Slice 2: controllers + UI (create/drop from a cluster page).

## Slices

1. **Models + client** — `DatabaseCluster`, `Database`, `PostgresClusterClient` (SQL over SSH). ✅ shipped (test-first)
2. **UI** — cluster page: list/create/drop databases; show connection details. ← next
3. **Wire-in** — link a created Database to an App's deploy config; "provision DB" from the app.
