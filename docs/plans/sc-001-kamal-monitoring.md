# SC-001: Kamal App Monitoring Dashboard - Implementation Plan

## Summary

Implement a dashboard to monitor Kamal/Docker apps with holistic views, one-click restart, and live log streaming.

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| CLI to use | **Docker commands** (not Kamal CLI) | Already used in codebase, guaranteed present, simpler |
| App discovery | **Manual + Docker sync** | Keep current registration, add sync feature |
| Log streaming | **Polling with Turbo refresh** | Simple, reliable, works with existing patterns |

---

## Implementation Phases

### Phase 1: Database Schema

**Migration: Add container tracking fields to apps**

```ruby
add_column :apps, :container_status, :string, default: "unknown"
add_column :apps, :container_started_at, :datetime
add_column :apps, :last_status_check_at, :datetime
add_column :apps, :status_check_error, :string
add_index :apps, :container_status
```

**Update App model** (`app/models/app.rb`):
- Add scopes: `healthy`, `unhealthy`, `needs_status_check`
- Add methods: `container_running?`, `needs_attention?`

---

### Phase 2: Container Status Service

**Create `app/services/container_status.rb`**:
- Run `docker inspect` via SSH
- Parse container state (running/exited/dead)
- Update app record with status

**Create `app/jobs/sync_container_status_job.rb`**:
- Sync single app or all apps
- Run periodically (every minute)

---

### Phase 3: Enhanced Dashboard

**Update `app/controllers/dashboard_controller.rb`**:
```ruby
@kamal_stats = {
  total_apps: @apps.count,
  running_apps: @apps.where(container_status: "running").count,
  stopped_apps: @apps.where(container_status: %w[exited dead]).count,
  unknown_status: @apps.where(container_status: "unknown").count
}
@apps_by_server = @apps.includes(:server).group_by(&:server)
```

**Create `app/views/dashboard/_kamal_overview.html.erb`**:
- Stats cards: Running / Stopped / Unhealthy / Unknown
- Apps grouped by server with status indicators
- Restart button per app

---

### Phase 4: One-Click Restart

**Create `app/jobs/restart_app_job.rb`**:
- Run `docker restart` via SSH
- Update app status on success/failure
- Trigger status sync after restart

**Update `app/controllers/apps_controller.rb`**:
- Change `restart` action to enqueue background job
- Add `sync_status` and `sync_all` actions

---

### Phase 5: Live Log Viewing

**Update `app/views/apps/logs.html.erb`**:
- Dark terminal-style log viewer
- Auto-refresh toggle (3-second polling)
- Manual refresh button

**Update `app/controllers/apps_controller.rb`**:
- Add JSON response to `logs` action for polling

---

### Phase 6: Routes & Scheduling

**Update `config/routes.rb`**:
```ruby
resources :apps do
  member do
    post :sync_status
  end
  collection do
    post :sync_all
  end
end
```

**Update `config/recurring.yml`**:
```yaml
sync_container_statuses:
  class: SyncContainerStatusJob
  schedule: every 1 minute
```

---

## Files to Create

| File | Purpose |
|------|---------|
| `db/migrate/*_add_container_status_to_apps.rb` | Schema changes |
| `app/services/container_status.rb` | Docker inspect wrapper |
| `app/jobs/sync_container_status_job.rb` | Status sync job |
| `app/jobs/restart_app_job.rb` | Background restart |
| `app/views/dashboard/_kamal_overview.html.erb` | Dashboard widget |

## Files to Modify

| File | Changes |
|------|---------|
| `app/models/app.rb` | Add status fields, scopes |
| `app/controllers/dashboard_controller.rb` | Kamal stats |
| `app/controllers/apps_controller.rb` | Sync actions, JSON logs |
| `app/views/dashboard/index.html.erb` | Include overview partial |
| `app/views/apps/logs.html.erb` | Terminal-style with refresh |
| `app/views/apps/show.html.erb` | Container status display |
| `config/routes.rb` | New sync routes |
| `config/recurring.yml` | Scheduled sync job |

---

## Verification

1. **Run migrations**: `bin/rails db:migrate`
2. **Test status sync**: Register a server with SSH, add an app, run `SyncContainerStatusJob.perform_now`
3. **Test dashboard**: Visit `/` and verify Kamal overview shows apps by server
4. **Test restart**: Click restart on an app, verify job runs and status updates
5. **Test logs**: Visit app logs page, verify logs load and auto-refresh works
6. **Run tests**: `bin/rails test`
