# Handoff: serialize per-app deploys + auto-heal stale kamal locks

**Date:** 2026-06-28
**From:** kuickr deploy session (app/5)
**Severity:** 🟠 important — causes failed deploys + a leaked lock that blocks all
subsequent deploys of the app until manually cleared.

## What happened

A kuickr deploy (Conductor deployment **#60**, commit `4250ea2`) **failed** with:

```
ERROR (Kamal::Cli::LockError): Deploy lock found. Run 'kamal lock help' for more information
ERROR: kamal deploy failed (exit 1)
```

`kamal lock status` then showed a **stale** lock owned by the same commit:

```
Locked by:  at 2026-06-28T03:14:57Z
Version: 4250ea2d716a28a9bfdf2100fc6fd500cc4f02de
Message: Automatic deploy lock
```

No deploy was actually running (#60 was the latest and it had failed). The lock
had to be cleared manually (`kamal lock release -r web`) before the app could
deploy again — Conductor did **not** self-heal it.

## Root cause

Two deploys of the **same app** ran concurrently (a UI/MCP trigger + a parallel
trigger). Kamal takes a global per-service "Automatic deploy lock" at the start of
`kamal deploy` and releases it in an `ensure`. When two run at once, one grabs the
lock and the other dies on `LockError`; if a kamal process is killed mid-run the
`ensure` never fires → **leaked lock**.

Conductor *has* a guard but it is **not atomic**:

```ruby
# app/tools/deploy_app_tool.rb
return Result.fail("A deployment is already in progress for #{app.name}.") if app.deployments.in_progress.any?
deployment = app.deployments.create!(user: @user)
DeployAppJob.perform_later(deployment.id)
```

`in_progress.any?` → `create!` is a **TOCTOU race**: two concurrent calls both read
"none in progress," both create a Deployment, both enqueue `DeployAppJob`, both run
`kamal deploy`. The check guards the slow/sequential case but not concurrent
triggers — which is exactly what "say 'trigger deploy' in chat" can produce (rapid
duplicate MCP calls, or MCP + the UI Deploy button).

(`Deployment::STATUSES = pending building deploying succeeded failed cancelled`;
`scope :in_progress, status IN (pending,building,deploying)`.)

## Required fixes

### 1. Atomic single-flight per app (the actual root cause)
Make "at most one in-progress deployment per app" a **DB invariant**, not an
application-level check. Either:

- **Unique partial index** (preferred, simplest):
  ```ruby
  add_index :deployments, :app_id, unique: true,
    where: "status IN ('pending','building','deploying')",
    name: "idx_one_active_deploy_per_app"
  ```
  Then `create!` raises `RecordNotUnique` on the second concurrent trigger →
  rescue it and return `Result.fail("A deployment is already in progress…")`.
- **Or** wrap check+create in `app.with_advisory_lock("deploy-#{app.id}") { … }`.

This closes the race for **all** trigger paths (MCP, chat, UI button) at once.

### 2. Auto-heal a stale kamal lock
In the kamal deploy path (DeployAppJob / KamalDeployer), before `kamal deploy`:
- detect a stale lock — a kamal lock present while **no** `Deployment` for that app
  is `in_progress` (other than this one) — and run `kamal lock release` first; **or**
- on `LockError`, if no sibling deploy is actually running, `kamal lock release`
  then retry once.
- Always attempt `kamal lock release` in an `ensure`/rescue when a deploy fails, so
  a crash never leaves the app wedged.

### 3. MCP / chat idempotency (the user's explicit ask)
"When I say 'trigger deploy' in chat, the MCP must run **exactly one** deploy."
With (1) in place this is mostly solved (the 2nd concurrent call fails cleanly
instead of colliding). Additionally:
- `deploy_app` should be **idempotent within a short window**: if an in-progress
  (or just-created, <Ns old) deployment for the app exists, return that
  deployment's id with `status: "already_running"` instead of erroring or starting
  a second — so a double-fire from chat is a no-op, not a failure.

## Acceptance
- Fire `deploy_app` twice concurrently for one app → exactly one `kamal deploy`
  runs; the second returns "already running" (no `LockError`, no leaked lock).
- Kill a deploy mid-run → next `deploy_app` clears the stale lock and proceeds.
- No manual `kamal lock release` ever needed.

## Evidence / repro
- kuickr app id 5; deployment #60 failed 2026-06-28 03:14 with `LockError`.
- Tail: `… kamal app logs -r web` (host `135.181.114.59`, devops vault creds).
