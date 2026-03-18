# Conductor Phase 3: App Deployment

## Summary
Docker-based app deployment via SSH. Clone repo, build image, run container - all orchestrated from Conductor without agents.

## Architecture

```
┌─────────────────┐     SSH      ┌─────────────────────────────┐
│   Conductor     │ ──────────►  │   Server                    │
│                 │              │   /opt/conductor/apps/      │
│   1. git clone  │              │   ├── app-slug/             │
│   2. docker build              │   │   └── (repo files)      │
│   3. docker run │              │   └── app-slug-2/           │
│                 │              │                             │
│   Background    │              │   Docker Containers:        │
│   Job (Solid)   │              │   ├── conductor-app-slug    │
└─────────────────┘              │   └── conductor-app-slug-2  │
                                 └─────────────────────────────┘
```

## Components

### Models

**App** (enhanced)
- `repository_url` - Git repo URL
- `branch` - Branch to deploy (default: main)
- `dockerfile_path` - Path to Dockerfile
- `image_name` - Docker image name
- `health_check_path` - Health check endpoint
- `ssl_enabled` - Enable SSL
- `deployed_at` - Last deployment time

**EnvVariable**
- `app_id` - Belongs to app
- `key` - Variable name (uppercase)
- `value` - Encrypted value
- `secret` - Boolean (masked in UI)

**Deployment**
- `app_id` - Belongs to app
- `user_id` - Who triggered
- `status` - pending/building/deploying/succeeded/failed/cancelled
- `commit_sha` - Git commit
- `log` - Deployment output
- `started_at`, `completed_at` - Timing

### Services

**AppDeployer**
Orchestrates the deployment via SSH:
1. Ensure Docker installed
2. Clone/pull repository
3. Build Docker image
4. Stop old container
5. Start new container with env vars
6. Health check
7. Cleanup old images

### Jobs

**DeployAppJob**
Background job that runs AppDeployer for async deployments.

## Routes

```ruby
resources :apps do
  member do
    post :deploy
    post :stop
    post :restart
    get :logs
  end
  resources :env_variables, only: [:create, :update, :destroy]
end
resources :deployments, only: [:show]
```

## Deployment Flow

1. User clicks "Deploy" on app page
2. Deployment record created with status "pending"
3. DeployAppJob enqueued
4. AppDeployer runs via SSH:
   - Clones repo to `/opt/conductor/apps/{slug}`
   - Builds Docker image
   - Starts container with env vars
   - Runs health check
5. Deployment marked succeeded/failed
6. User can view logs in real-time

## Files Created

### Migrations
- `db/migrate/*_add_deployment_fields_to_apps.rb`
- `db/migrate/*_create_env_variables.rb`
- `db/migrate/*_create_deployments.rb`

### Models
- `app/models/env_variable.rb`
- `app/models/deployment.rb`

### Services
- `app/services/app_deployer.rb`

### Jobs
- `app/jobs/deploy_app_job.rb`

### Controllers
- `app/controllers/env_variables_controller.rb`
- `app/controllers/deployments_controller.rb`

### Views
- `app/views/apps/show.html.erb` (updated)
- `app/views/apps/_form.html.erb` (updated)
- `app/views/apps/logs.html.erb`
- `app/views/deployments/show.html.erb`

## Usage

### Creating an App
1. Go to /apps/new
2. Fill in name, select server
3. Add repository URL and branch
4. Save

### Deploying
1. View app at /apps/:id
2. Click "Deploy" button
3. Watch deployment logs at /deployments/:id
4. App starts running when deployment succeeds

### Environment Variables
1. On app show page, scroll to "Environment Variables"
2. Add key/value pairs
3. Mark as "Secret" to mask in UI
4. Variables are passed to container on next deploy

### Container Management
- **Restart**: Restart running container
- **Stop**: Stop container
- **Logs**: View last 100 lines of container logs

## Security

- Env variable values encrypted at rest
- SSH keys used for server access (no passwords)
- Secrets masked in UI
- Health checks ensure app is running before marking deploy as success

## Future Enhancements

- [ ] Rollback to previous deployment
- [ ] Zero-downtime deployments (blue/green)
- [ ] Deploy hooks (before/after)
- [ ] Slack/Discord notifications
- [ ] Auto-deploy on git push (webhooks)
- [ ] Caddy/Traefik reverse proxy configuration
- [ ] SSL certificate management
