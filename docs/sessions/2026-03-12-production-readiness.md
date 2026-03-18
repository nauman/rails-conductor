# Session: Production Readiness — Fix Everything That's Broken

**Date:** 2026-03-12
**Scope:** 79-Conductor
**Goal:** Fix database schema mismatches so the full deployment pipeline works end-to-end

---

## What Was Done

### 1. Database Schema Fixes

**Problem:** `schema.rb` was out of sync with model code. The `servers` table was missing `ssh_key_id` and `metrics_updated_at`. The `deployments` table had `script_id`/`server_id` (for script runs) but was missing `app_id`, `started_at`, `completed_at` (for app deployments).

**Root cause:** Migration `20250202100006` added SSH fields to servers, but the schema was regenerated from a DB that didn't have them. The deployments table was recreated at some point with script_run-style columns instead of app-deployment columns.

**Fix:**
- Created `20260312120001_add_ssh_key_and_metrics_to_servers.rb` — idempotent, adds `ssh_key_id` (FK) and `metrics_updated_at`
- Created `20260312120002_fix_deployments_table.rb` — adds `app_id` (FK), `started_at`, `completed_at`, `commit_sha`; makes `script_id`/`server_id`/`user_id` nullable

### 2. Deployment Model Fix

Added `belongs_to :server, optional: true` to `Deployment` model (column existed but association was missing).

### 3. ActionCable Deploy Streaming

**Before:** Deployment show page used `setTimeout(5000)` to reload the entire page every 5 seconds.

**After:** Real-time streaming via ActionCable:
- Created `app/channels/deploy_channel.rb` — streams `deployment_{id}`
- Updated `AppDeployer#log` to broadcast each line via ActionCable
- Updated `show.html.erb` — ActionCable subscription appends log lines live, reloads on completion

### 4. Seeds

Added deployment seed data with realistic log output for the two seeded apps.

---

## Files Changed

| File | Change |
|------|--------|
| `db/migrate/20260312120001_add_ssh_key_and_metrics_to_servers.rb` | New migration |
| `db/migrate/20260312120002_fix_deployments_table.rb` | New migration |
| `db/schema.rb` | Regenerated |
| `app/models/deployment.rb` | Added `belongs_to :server, optional: true` |
| `app/channels/deploy_channel.rb` | New ActionCable channel |
| `app/services/app_deployer.rb` | Added ActionCable broadcasting |
| `app/views/deployments/show.html.erb` | Replaced setTimeout with ActionCable |
| `db/seeds.rb` | Added deployment seeds |

---

## Verification

- `bin/rails db:migrate` — both migrations ran cleanly
- `RAILS_ENV=test bin/rails db:drop db:create db:schema:load` — fresh setup works
- Schema now has all columns that models reference
- Dashboard query `Deployment.includes(:app, :user)` will work (app_id column exists)
- Deploy page streams logs in real-time instead of reloading
