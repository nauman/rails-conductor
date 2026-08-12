# Edge-Aware Kamal Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewire Kamal edge commands through Conductor so Caddy remains authoritative while Kamal-proxy retains native behavior, and ensure live-container operations always use `--reuse`.

**Architecture:** Add one Conductor service boundary that classifies edge operations before any shell command. Caddy operations use `CaddyClient` and desired app route state; Kamal-proxy operations use Kamal's command surface. Read-only app commands remain in `KamalOps` and all container execs use `app exec --reuse`.

**Tech Stack:** Rails 8, Active Record, SSH-backed Caddy Admin API, Kamal 2.12, Minitest.

---

### Task 1: Define the command policy

**Files:**
- Create: `app/services/edge_operations.rb`
- Test: `test/services/edge_operations_test.rb`

- [x] Write failing tests for edge-specific command classification and Caddy prohibition of Kamal proxy/redeploy/maintenance/live commands.
- [x] Implement the smallest policy boundary.
- [x] Run focused tests.

### Task 2: Add reversible maintenance/live route behavior

**Files:**
- Modify: `app/services/caddy_client.rb`
- Modify: `app/services/edge/caddy_adapter.rb`
- Modify: `app/services/edge/kamal_proxy_adapter.rb`
- Create: migration for app maintenance state
- Test: adapter and service tests

- [x] Write failing tests for Caddy 503 maintenance and route restoration.
- [x] Implement route replacement/restoration without touching unrelated routes.
- [x] Implement Kamal-proxy delegation boundary.
- [x] Run focused tests.

### Task 3: Add safe redeploy/proxy entrypoints

**Files:**
- Modify: `app/services/edge_operations.rb`
- Modify: `app/services/kamal_ops.rb`
- Test: `test/services/edge_operations_test.rb`, `test/services/kamal_ops_test.rb`

- [x] Write failing tests proving Caddy cannot invoke generic `kamal redeploy` or proxy commands.
- [x] Route authorized redeploy to the existing deployment transaction only.
- [x] Keep Caddy app operations on the existing container.
- [x] Run focused tests.

### Task 4: Self-review and verification

- [x] Run the full test suite.
- [x] Review every new shell command for accidental container creation or edge-port ownership.
- [x] Update `docs/infra/DEPLOY-TODO.md` with completed status and residual risks.
- [x] Run `git diff --check` and report any unrelated pre-existing failures.
