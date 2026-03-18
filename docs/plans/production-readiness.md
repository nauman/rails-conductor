# 79-Conductor: Production Readiness Plan

## Status: Implemented (2026-03-12)

## Problem

Conductor had working infrastructure (SSH, script execution, container tracking, backups) but the **app deployment pipeline was broken** due to database schema mismatches. The `deployments` table had the wrong columns, the `servers` table was missing SSH key references, and the dashboard would crash on load.

## Root Cause

The `schema.rb` was out of sync with both the migration files and the model code:
- **servers**: Migration `20250202100006` added `ssh_key_id` and `metrics_updated_at`, but `schema.rb` didn't reflect them
- **deployments**: Original migration created with `app_id`, `started_at`, `completed_at`, but `schema.rb` had `script_id`/`server_id` instead (table was recreated incorrectly at some point)

## What Was Fixed

### Migration 1: `20260312120001_add_ssh_key_and_metrics_to_servers`
- Added `ssh_key_id` (FK to ssh_keys) — Server model does `belongs_to :ssh_key`
- Added `metrics_updated_at` — Server model calls `update!(metrics_updated_at: Time.current)`

### Migration 2: `20260312120002_fix_deployments_table`
- Added `app_id` (FK to apps) — Deployment model does `belongs_to :app`
- Added `started_at`, `completed_at` — used by `start!`, `succeed!`, `fail!`, `duration`
- Added `commit_sha` — matches original migration intent
- Made `script_id`, `server_id`, `user_id` nullable (script runs use ScriptRun, not Deployment)

### Model Fix: `app/models/deployment.rb`
- Added `belongs_to :server, optional: true`

### New: Deploy Streaming via ActionCable
- Created `app/channels/deploy_channel.rb` — streams `deployment_{id}`
- Updated `app/services/app_deployer.rb` — broadcasts log lines and status changes
- Updated `app/views/deployments/show.html.erb` — replaced `setTimeout` reload with ActionCable subscription

### Seeds
- Added deployment seed data with realistic log output

## Verification

1. `bin/rails db:migrate` — runs cleanly
2. `RAILS_ENV=test bin/rails db:drop db:create db:schema:load` — works for fresh setup
3. Dashboard loads without crashes
4. Deployment show page streams logs in real-time
