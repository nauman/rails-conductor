# Operational Dashboard Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Overview report truthful, actionable app health without missing Turbo content, contradictory statuses, ambiguous actions, or viewport clipping.

**Architecture:** Add an `AppHealth` PORO that derives desired, observed, and monitoring state plus at most one runtime/monitoring incident per app. Keep deployment incidents separate in `DashboardController`; render the same health object in the incident queue and server-grouped fleet table. Preserve server-rendered ERB and lazy Turbo Frames, with no new schema or client-rendered state.

**Tech Stack:** Rails 8, Active Record, ERB, Turbo Frames, Importmaps, Tailwind, Minitest.

**Source contract:** `docs/plans/monitoring-ops.md`, section “Operational Dashboard Health Design.”

---

## File map

- Create `app/models/app_health.rb` — derive desired/observed/monitoring state, labels, freshness, action hint, and one app incident.
- Create `test/models/app_health_test.rb` — exhaustive state/monitoring matrix.
- Create `test/integration/dashboard_health_test.rb` — organization-scoped incident and fleet rendering contract.
- Create `test/integration/app_jobs_test.rb` — canonical Turbo Frame, unavailable-data, full-page, and unexpected-frame behavior.
- Create `test/services/solid_queue_stats_test.rb` — availability and fallback behavior for the existing in-progress jobs service.
- Modify `app/models/app.rb` — shared restart/status-sync support predicates only.
- Modify `app/controllers/dashboard_controller.rb` — build health objects, stats, server groups, and deduplicated app incidents.
- Modify `app/controllers/apps_controller.rb` — guard restart consistently and make the jobs response explicit.
- Modify `app/views/apps/_jobs_badge.html.erb` — canonical frame wrapper and “No job data” fallback.
- Modify `app/views/apps/jobs.html.erb` — preserve the existing in-progress full jobs page and reconcile it with the frame contract.
- Modify `app/services/solid_queue_stats.rb` — preserve the existing in-progress service and make only changes required by response tests.
- Modify `app/views/dashboard/_kamal_overview.html.erb` — responsive fleet table, monitoring context, and labelled actions.
- Modify `app/views/dashboard/index.html.erb` — incident-first queue wording and actions.
- Modify `app/views/layouts/application.html.erb` — contain navigation/account controls at 390 px and 1024 px.
- Modify `docs/plans/monitoring-ops.md` and `docs/dev/CHANGELOG.md` only after verification to record delivered acceptance criteria.

### Task 0: Dirty-worktree preflight and baseline

**Files:**
- Inspect only: `.gitignore`
- Inspect/preserve: `docs/threads/self-describing-deploys.thread.md`
- Inspect/integrate: `app/services/solid_queue_stats.rb`
- Inspect/integrate: `app/views/apps/_jobs_badge.html.erb`
- Inspect/integrate: `app/views/apps/jobs.html.erb`

- [ ] **Step 1: Record the pre-existing worktree state**

Run: `git status --short && git diff -- .gitignore docs/threads/self-describing-deploys.thread.md`

Expected: unrelated `.gitignore` and deploy-thread changes remain visible; the three jobs files are untracked in-progress work that overlaps this feature.

- [ ] **Step 2: Inspect the overlapping jobs files before editing**

Read all three files completely. Treat their Solid Queue behavior and full-page jobs UI as user work to preserve and integrate, not replace.

- [ ] **Step 3: Run the baseline suite**

Run: `bin/rails test`

Expected: establish the exact pre-change run/failure count. If failures exist, determine whether they are baseline failures before continuing.

- [ ] **Step 4: Protect unrelated changes**

Do not stage `.gitignore` or `docs/threads/self-describing-deploys.thread.md` in feature commits. Every later `git add` names exact files.

### Task 1: App health state model

**Files:**
- Create: `test/models/app_health_test.rb`
- Create: `app/models/app_health.rb`
- Modify: `app/models/app.rb`

- [ ] **Step 1: Write failing desired-state and monitoring-precedence tests**

Cover these expectations with fixtures or locally created records:

```ruby
test "stopped is desired stopped while lifecycle states remain desired running" do
  assert_equal "stopped", AppHealth.new(app(status: "stopped")).desired_state
  %w[running deploying failed].each do |status|
    assert_equal "running", AppHealth.new(app(status: status)).desired_state
  end
end

test "monitoring precedence is unsupported unavailable failed never stale fresh" do
  assert_equal "unsupported", health(deploy_method: "native").monitoring_state
  assert_equal "unavailable", health(server: nil).monitoring_state
  assert_equal "failed", health(status_check_error: "ssh failed", last_status_check_at: Time.current).monitoring_state
  assert_equal "never_checked", health(last_status_check_at: nil).monitoring_state
  assert_equal "stale", health(last_status_check_at: 6.minutes.ago).monitoring_state
  assert_equal "fresh", health(last_status_check_at: 1.minute.ago).monitoring_state
end
```

In `test/models/app_test.rb`, first add failing tests for
`status_sync_supported?`, `restart_supported?`,
`dashboard_restart_supported?`, `can_sync_status?` delegation, and stale Kamal
status. These tests must fail before changing `App`.

- [ ] **Step 2: Run both model tests and verify RED**

Run: `bin/rails test test/models/app_health_test.rb test/models/app_test.rb`

Expected: error because `AppHealth` does not exist.

- [ ] **Step 3: Implement minimal state derivation**

Implement a PORO with `desired_state`, `observed_state`, `monitoring_state`, `monitoring_label`, and `last_checked_label`. Use the reviewed precedence exactly. Add to `App`:

```ruby
def status_sync_supported?
  docker? || kamal?
end

def restart_supported?
  server&.ssh_configured? && (docker? || kamal? || native?)
end

def dashboard_restart_supported?
  restart_supported? && (docker? || kamal?)
end
```

Make `can_sync_status?` delegate to `status_sync_supported? && server&.ssh_configured?`, and make stale behavior cover both Docker and Kamal.

- [ ] **Step 4: Run both model tests and verify GREEN**

Run: `bin/rails test test/models/app_health_test.rb test/models/app_test.rb`

Expected: all tests pass.

- [ ] **Step 5: Write failing incident-matrix tests**

Cover desired running against every observed state; desired stopped against fresh running/restarting versus stopped/unknown/non-fresh; unavailable and unsupported handling; and critical-over-warning precedence. Assert severity, wording, and primary action.

- [ ] **Step 6: Run the matrix tests and verify RED**

Run: `bin/rails test test/models/app_health_test.rb`

Expected: failures because `incident` is not implemented.

- [ ] **Step 7: Implement one app incident**

Return `nil` or a hash shaped like:

```ruby
{ type: "app", severity: "critical", resource: app,
  message: "Expected running, observed exited", action: "logs" }
```

Never emit “App is stopped” for unknown, stale, failed, unavailable, or unsupported monitoring.

- [ ] **Step 8: Run focused and existing App tests**

Run: `bin/rails test test/models/app_health_test.rb test/models/app_test.rb`

Expected: 0 failures, 0 errors.

- [ ] **Step 9: Commit**

```bash
git add app/models/app.rb app/models/app_health.rb test/models/app_health_test.rb test/models/app_test.rb
git commit -m "feat: model operational app health"
```

### Task 2: Dashboard aggregation and incident deduplication

**Files:**
- Create: `test/integration/dashboard_health_test.rb`
- Modify: `app/controllers/dashboard_controller.rb`

- [ ] **Step 1: Write failing integration tests**

Assert that:

- fresh desired-stopped/exited apps do not appear in Active incidents;
- desired-running/exited apps appear once with actionable mismatch wording;
- desired-stopped/running apps appear once as “Running unexpectedly”;
- failed/stale monitoring never says stopped;
- a failed deployment remains a separate deployment incident;
- all records remain scoped to `current_organization`.
- each summary bucket follows the exact fresh/observed classification below;
- `Running + Stopped + Unknown == Total` for mixed monitoring states.

- [ ] **Step 2: Run the integration test and verify RED**

Run: `bin/rails test test/integration/dashboard_health_test.rb`

Expected: stopped apps still appear as generic issues and health wording is absent.

- [ ] **Step 3: Replace app issue loops with `AppHealth` aggregation**

Build `@app_health_by_id`, group health objects by server, and append only
`health.incident`. Summary cards classify each app exactly once:

- Running: monitoring fresh + observed running/restarting.
- Stopped: monitoring fresh + observed exited/dead/paused.
- Unknown: fresh observed unknown, or any stale/failed/never/unavailable/unsupported monitoring state.
- Total: all apps; Running + Stopped + Unknown must equal Total.

Remove the generic stale/failed/stopped app loops. Keep server, deployment, and
backup issue sources unchanged. Map app incident actions explicitly: runtime
mismatch → Logs (with Restart secondary when supported); monitoring uncertainty
→ Sync; fresh desired-stopped + running/restarting → app details, where Stop is
already available.

- [ ] **Step 4: Run integration and controller-adjacent tests**

Run: `bin/rails test test/integration/dashboard_health_test.rb test/integration/server_scoping_test.rb`

Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/dashboard_controller.rb test/integration/dashboard_health_test.rb
git commit -m "feat: derive dashboard incidents from operational health"
```

### Task 3: Repair the jobs Turbo Frame contract

**Files:**
- Create: `test/integration/app_jobs_test.rb`
- Create: `test/services/solid_queue_stats_test.rb`
- Modify: `app/controllers/apps_controller.rb`
- Modify: `app/services/solid_queue_stats.rb`
- Modify: `app/views/apps/_jobs_badge.html.erb`
- Modify: `app/views/apps/jobs.html.erb`

- [ ] **Step 1: Write failing response-contract tests**

For `GET /apps/:id/jobs`, assert:

```ruby
get jobs_app_path(app), headers: { "Turbo-Frame" => "app_jobs_#{app.id}" }
assert_response :success
assert_select "turbo-frame#app_jobs_#{app.id}", count: 1
```

Also assert normal HTML renders the existing full jobs page, unavailable stats
render “No job data,” and an unexpected frame ID returns a full HTML page rather
than a frameless response. Add focused service tests around the existing
`SolidQueueStats` availability/error contract before changing that service.

- [ ] **Step 2: Run the Turbo and service tests and verify RED**

Run: `bin/rails test test/integration/app_jobs_test.rb test/services/solid_queue_stats_test.rb`

Expected: the canonical frame request lacks its expected frame or fallback copy differs.

- [ ] **Step 3: Make frame selection explicit**

Render the badge partial only for the canonical frame request; keep normal and unexpected-frame requests on `jobs.html.erb`. Ensure the partial owns exactly one canonical `turbo_frame_tag` and renders “No job data” when unavailable.

- [ ] **Step 4: Run the Turbo and service tests and verify GREEN**

Run: `bin/rails test test/integration/app_jobs_test.rb test/services/solid_queue_stats_test.rb`

Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/apps_controller.rb app/services/solid_queue_stats.rb app/views/apps/_jobs_badge.html.erb app/views/apps/jobs.html.erb test/integration/app_jobs_test.rb test/services/solid_queue_stats_test.rb
git commit -m "fix: return canonical jobs Turbo frames"
```

### Task 4: Incident-first and responsive fleet UI

**Files:**
- Modify: `test/integration/dashboard_health_test.rb`
- Modify: `app/views/dashboard/_kamal_overview.html.erb`
- Modify: `app/views/dashboard/index.html.erb`

- [ ] **Step 1: Write failing rendering assertions**

Assert the response contains Active incidents, Fleet status, desired/observed/monitoring labels, last-check context, and visible Sync/Logs/Restart text. Assert restart has `data-turbo-confirm`, and Sync and Restart remain distinct controls.

- [ ] **Step 2: Run the rendering tests and verify RED**

Run: `bin/rails test test/integration/dashboard_health_test.rb`

Expected: old “Attention Required,” icon-only actions, and missing monitoring labels fail assertions.

- [ ] **Step 3: Rewrite the fleet partial**

Render health objects instead of raw ambiguous status. Use `grid-cols-2 sm:grid-cols-4`; stack rows below `sm`; show concise error text; provide labelled Sync, Logs, Restart controls; show Restart only for `dashboard_restart_supported?`; add confirmation; preserve server grouping and lazy jobs badge.

- [ ] **Step 4: Rewrite the incident queue**

Use “Active incidents,” severity-specific wording, and action links based on each issue's `action`. Keep server/deployment/backup links and the five-item limit with a useful “more incidents” link or count.

- [ ] **Step 5: Run dashboard tests and verify GREEN**

Run: `bin/rails test test/integration/dashboard_health_test.rb`

Expected: 0 failures, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add app/views/dashboard/_kamal_overview.html.erb app/views/dashboard/index.html.erb test/integration/dashboard_health_test.rb
git commit -m "feat: make dashboard health actionable"
```

### Task 5: Guard restart and contain the application header

**Files:**
- Modify: `test/integration/dashboard_health_test.rb`
- Create: `test/integration/app_restart_test.rb`
- Modify: `app/controllers/apps_controller.rb`
- Modify: `app/views/layouts/application.html.erb`

- [ ] **Step 1: Write failing restart guard tests**

Assert unsupported/missing-SSH restart requests do not enqueue `RestartAppJob` and redirect with a clear alert. Assert Docker/Kamal/native apps with SSH remain controller-supported.

- [ ] **Step 2: Run restart tests and verify RED**

Run: `bin/rails test test/integration/app_restart_test.rb`

Expected: current controller enqueues without checking support.

- [ ] **Step 3: Add the controller guard**

Use `@app.restart_supported?` before enqueueing. Do not narrow the controller to dashboard-only Docker/Kamal support.

- [ ] **Step 4: Add failing responsive-contract assertions**

Assert the header has a bounded `min-w-0` nav region, shrink-safe account
controls, and responsive visibility classes. Assert fleet counters use
`grid-cols-2 sm:grid-cols-4`, rows stack below `sm`, and controls have visible
labels plus `data-turbo-confirm`. These are structural regression checks;
viewport behavior is verified in Task 6.

- [ ] **Step 5: Repair layout containment**

Keep the nav horizontally scrollable inside available width, reduce narrow-width gaps/padding, keep Sign out inside the viewport, and ensure sticky-header spacing does not obscure dashboard headings.

- [ ] **Step 6: Run focused tests**

Run: `bin/rails test test/integration/app_restart_test.rb test/integration/dashboard_health_test.rb`

Expected: 0 failures, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add app/models/app.rb app/controllers/apps_controller.rb app/views/layouts/application.html.erb test/integration/app_restart_test.rb test/integration/dashboard_health_test.rb
git commit -m "fix: guard restart and contain dashboard navigation"
```

### Task 6: Full verification and delivery records

**Files:**
- Modify: `docs/plans/monitoring-ops.md`
- Modify: `docs/dev/CHANGELOG.md`
- Update relevant `docs/threads/*.thread.md` only if another role depends on the result.

- [ ] **Step 1: Run focused feature tests**

Run:

```bash
bin/rails test \
  test/models/app_health_test.rb \
  test/models/app_test.rb \
  test/integration/dashboard_health_test.rb \
  test/integration/app_jobs_test.rb \
  test/integration/app_restart_test.rb \
  test/integration/server_scoping_test.rb \
  test/services/solid_queue_stats_test.rb
```

Expected: 0 failures, 0 errors.

- [ ] **Step 2: Run the full Rails suite**

Run: `bin/rails test`

Expected: 0 failures, 0 errors.

- [ ] **Step 3: Verify in a real browser at 390 px, 1024 px, and desktop**

Run `bin/rails db:seed`, then create a deterministic verification identity:

```bash
bin/rails runner 'user = User.find_or_create_by!(email: "dashboard-verify@example.test"); user.ensure_personal_organization!; puts user.email'
```

Start the app with `bin/dev`, visit `/users/sign_in`, submit exactly
`dashboard-verify@example.test`, then open its magic link through
`/letter_opener`. Create verification app records through the UI so they belong
to this user's current organization; do not reuse unscoped seed apps. Then
verify:

- no “Content missing” text or Turbo console errors;
- Sign out and organization controls remain inside the viewport;
- no horizontal page overflow;
- headings remain visible below the sticky header;
- incident and fleet rows reflow without overlap;
- Sync, Logs, and Restart are distinguishable;
- Restart asks for confirmation.

Capture screenshots at 390 px and 1024 px as verification evidence. Do not commit screenshots unless the project already tracks UI evidence.

- [ ] **Step 4: Run documentation checks**

Run:

```bash
bash docs/scripts/ralph-doc-check.sh
docs/scripts/agent-thread-status.sh docs --me codex --me staff-engineer
```

Expected: doc check exits 0; no newly owed thread is left unanswered.

- [ ] **Step 5: Mark delivered acceptance criteria and changelog**

Check only criteria proven by tests/browser evidence. Add a concise changelog entry linking the plan; do not claim unverified behavior.

- [ ] **Step 6: Final verification after docs edits**

Run: `git diff --check && bin/rails test`

Expected: clean diff check and 0 failures, 0 errors.

- [ ] **Step 7: Commit delivery records**

```bash
git add docs/plans/monitoring-ops.md docs/dev/CHANGELOG.md
# Add a thread only when this task explicitly updated that exact file:
# git add docs/threads/<dashboard-topic>.thread.md
git commit -m "docs: record operational dashboard health delivery"
```
