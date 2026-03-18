# Conductor Phase 2: SSH-Based Server Monitoring

## Summary
Implement agentless server monitoring via SSH keys (similar to Hatchbox), eliminating the need for installing agents on monitored servers. Includes an SSH key vault for secure storage of private keys.

## Architecture

```
┌─────────────────┐     SSH      ┌─────────────────┐
│   Conductor     │ ──────────►  │   Server 1      │
│   (Rails App)   │              └─────────────────┘
│                 │     SSH      ┌─────────────────┐
│   SSH Key Vault │ ──────────►  │   Server 2      │
│   (Encrypted)   │              └─────────────────┘
│                 │     SSH      ┌─────────────────┐
│   Background    │ ──────────►  │   Server N      │
│   Jobs (Solid)  │              └─────────────────┘
└─────────────────┘
```

## Components

### 1. SSH Key Vault (SshKey Model)
- Stores private keys with Rails encrypted attributes
- Extracts and stores public key + fingerprint
- Supports RSA, DSA, ECDSA, ED25519 key types
- Optional passphrase protection

### 2. Server SSH Configuration
- Each server links to an SSH key
- Configurable SSH user (default: root)
- Configurable SSH port (default: 22)
- `ssh_configured?` helper for UI conditionals

### 3. SSH Connection Service
- Wraps net-ssh for connection handling
- Test connection functionality
- Execute arbitrary commands
- Timeout handling (30s default)

### 4. Server Metrics Service
- CPU usage via `top` command
- Memory used/total via `free` command
- Disk usage via `df` command
- Uptime via `uptime` command
- Parses and updates server model

### 5. Background Polling
- RefreshServerMetricsJob runs every 5 minutes
- Enqueues individual jobs per server
- Marks servers offline on connection failure
- Uses Solid Queue recurring jobs

## Files Created

### Migrations
- `db/migrate/20250202100005_create_ssh_keys.rb`
- `db/migrate/20250202100006_add_ssh_fields_to_servers.rb`

### Models
- `app/models/ssh_key.rb` - Encrypted key storage with fingerprint extraction

### Services
- `app/services/ssh_connection.rb` - SSH connectivity wrapper
- `app/services/server_metrics.rb` - Fetch metrics via SSH commands

### Controllers
- `app/controllers/ssh_keys_controller.rb` - Full CRUD for SSH keys

### Views
- `app/views/ssh_keys/index.html.erb`
- `app/views/ssh_keys/show.html.erb`
- `app/views/ssh_keys/new.html.erb`
- `app/views/ssh_keys/edit.html.erb`
- `app/views/ssh_keys/_form.html.erb`

### Jobs
- `app/jobs/refresh_server_metrics_job.rb`

### Configuration
- `config/recurring.yml` - Updated with refresh_server_metrics job

## Routes Added

```ruby
resources :ssh_keys
resources :servers do
  member do
    post :test_connection
    post :refresh_metrics
  end
end
```

## Usage

### Adding an SSH Key
1. Navigate to /ssh_keys/new
2. Enter a name (e.g., "production-key")
3. Paste the private key (PEM format)
4. Optionally add a passphrase
5. Save - fingerprint is auto-extracted

### Connecting a Server
1. Edit the server
2. Select an SSH key from the dropdown
3. Configure SSH user and port if needed
4. Save and click "Test Connection"

### Manual Metrics Refresh
Click "Refresh Metrics" button on server show page

### Automatic Polling
Metrics refresh automatically every 5 minutes via background job

## Security Considerations

- Private keys encrypted at rest using Rails credentials
- Keys never logged or exposed in views
- SSH connections use key-based auth only (no passwords)
- Passphrase support for additional key protection
- Connection timeouts prevent hanging

## Dependencies Added

```ruby
gem "net-ssh", "~> 7.2"
gem "ed25519", "~> 1.3"      # ED25519 key support
gem "bcrypt_pbkdf", "~> 1.1" # Required for ED25519
```

## Testing

```bash
# Start the app
bin/dev

# Create an SSH key at /ssh_keys/new
# Edit a server to add SSH configuration
# Click "Test Connection" to verify
# Click "Refresh Metrics" to pull stats
# Check recurring job runs: bin/jobs
```

## Future Enhancements

- [ ] SSH key generation within Conductor
- [ ] Key rotation reminders
- [ ] Connection health history
- [ ] Alerts on metric thresholds
- [ ] Multi-command execution (deploy scripts)
