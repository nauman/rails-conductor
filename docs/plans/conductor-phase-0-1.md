# Conductor Phase 0/1: Core Models + Dashboard Shell

## Summary
Build foundational data models and wire up the dashboard with real database queries, replacing mock data.

## Models to Create

| Model | Purpose | Key Fields |
|-------|---------|------------|
| **Server** | VM/host to monitor | name, ip_address, provider, status, cpu/memory/disk %, agent_url/token |
| **Credential** | API keys (encrypted) | name, provider, api_key, api_secret, active |
| **App** | Deployed Rails app | name, slug, server_id, container_id, port, domain, status |
| **Backup** | Backup history | server_id, app_id, provider, bucket_name, size_bytes, status |

## Files to Create/Modify

### Migrations (4 new files)
- `db/migrate/*_create_servers.rb`
- `db/migrate/*_create_credentials.rb`
- `db/migrate/*_create_apps.rb`
- `db/migrate/*_create_backups.rb`

### Models (4 new files)
- `app/models/server.rb` - PROVIDERS, STATUSES, scopes, helper methods (formatted_uptime, formatted_memory)
- `app/models/credential.rb` - `encrypts :api_key, :api_secret`, masked_api_key
- `app/models/app.rb` - belongs_to :server, auto-generate slug
- `app/models/backup.rb` - formatted_size, time_ago helpers

### Controllers (4 new + 1 update)
- `app/controllers/servers_controller.rb` - full CRUD
- `app/controllers/credentials_controller.rb` - CRUD except show
- `app/controllers/apps_controller.rb` - full CRUD
- `app/controllers/backups_controller.rb` - index/show only
- `app/controllers/dashboard_controller.rb` - UPDATE: real queries

### Views (15+ files)
- `servers/` - index, show, new, edit, _form
- `credentials/` - index, new, edit, _form
- `apps/` - index, show, new, edit, _form
- `backups/` - index, show
- `dashboard/index.html.erb` - UPDATE: real data + navigation links
- `layouts/application.html.erb` - UPDATE: add nav links

### Routes
```ruby
resources :servers
resources :credentials, except: [:show]
resources :apps
resources :backups, only: [:index, :show]
```

### Seeds
- `db/seeds.rb` - 3 servers, 3 credentials, 2 apps, 3 backups

## Implementation Order

1. Create 4 migrations → `rails db:migrate`
2. Create 4 models with validations/scopes
3. Update routes.rb
4. Create 4 controllers
5. Create server views (index, show, new, edit, _form)
6. Create credential views
7. Create app views
8. Create backup views
9. Update dashboard/index.html.erb with real data
10. Update layout with navigation
11. Add seed data → `rails db:seed`

## Key Design Decisions

- **No auth** - Single-user localhost mode for now
- **Encrypted credentials** - Rails 8 `encrypts` for API keys
- **Flexible backups** - Can belong to server OR app (both optional)
- **Reuse status_badge** - Extend existing helper for new statuses
- **Match existing Tailwind** - Follow patterns in current dashboard

## Verification

```bash
cd ../79-conductor
bin/rails db:migrate
bin/rails db:seed
bin/dev  # runs on port 3010

# Test in browser:
# - http://localhost:3010 (dashboard with real data)
# - http://localhost:3010/servers (CRUD)
# - http://localhost:3010/credentials (CRUD)
# - http://localhost:3010/apps (CRUD)
# - http://localhost:3010/backups (read-only)
```
