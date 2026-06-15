# Seeds for Conductor
# Run with: bin/rails db:seed

puts "Seeding database..."

# Demo data is for development/test only. Production seeds just the built-in
# provisioning Scripts (below) so the app reflects real infrastructure.
unless Rails.env.production?

# Servers
servers = [
  {
    name: "edge-hel1",
    ip_address: "95.217.123.45",
    provider: "hetzner",
    region: "Helsinki",
    status: "online",
    cpu_percent: 18,
    memory_used_mb: 4198,
    memory_total_mb: 8192,
    disk_percent: 42,
    last_seen_at: 2.minutes.ago
  },
  {
    name: "apps-nyc1",
    ip_address: "167.172.54.89",
    provider: "digitalocean",
    region: "New York",
    status: "online",
    cpu_percent: 31,
    memory_used_mb: 6348,
    memory_total_mb: 12288,
    disk_percent: 58,
    last_seen_at: 1.minute.ago
  },
  {
    name: "backup-fra1",
    ip_address: "116.203.78.12",
    provider: "hetzner",
    region: "Frankfurt",
    status: "degraded",
    cpu_percent: 74,
    memory_used_mb: 7987,
    memory_total_mb: 8192,
    disk_percent: 81,
    last_seen_at: 22.hours.ago
  }
]

servers.each do |attrs|
  Server.find_or_create_by!(name: attrs[:name]) do |server|
    server.assign_attributes(attrs)
  end
end
puts "  Created #{Server.count} servers"

# Credentials
credentials = [
  { name: "Production Cloudflare", provider: "cloudflare", api_key: "cf_live_abc123def456ghi789", active: true },
  { name: "Hetzner API", provider: "hetzner", api_key: "htz_sk_test_xyz789abc123def456", active: true },
  { name: "Backup AWS (Inactive)", provider: "aws", api_key: "AKIAIOSFODNN7EXAMPLE", api_secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", active: false }
]

credentials.each do |attrs|
  Credential.find_or_create_by!(name: attrs[:name]) do |cred|
    cred.assign_attributes(attrs)
  end
end
puts "  Created #{Credential.count} credentials"

# Apps
edge_server = Server.find_by(name: "edge-hel1")
apps_server = Server.find_by(name: "apps-nyc1")

apps = [
  { name: "InventList", server: apps_server, domain: "inventlist.com", port: 3000, status: "running", container_id: "inv_web_abc123", deploy_method: "docker" },
  { name: "Conductor", server: edge_server, domain: "conductor.local", port: 3010, status: "running", container_id: "cnd_web_def456", deploy_method: "docker" },
  { name: "MadeMySite", server: apps_server, domain: "mademysite.com", port: 3022, status: "running", deploy_method: "native", repository_url: "git@github.com:user/mademysite.git", branch: "main" }
]

apps.each do |attrs|
  App.find_or_create_by!(name: attrs[:name]) do |app|
    app.assign_attributes(attrs)
  end
end
puts "  Created #{App.count} apps"

# Backups
inventlist = App.find_by(name: "InventList")
backup_server = Server.find_by(name: "backup-fra1")

backups = [
  {
    server: backup_server,
    provider: "cloudflare_r2",
    bucket_name: "r2-postgres",
    size_bytes: 19_759_144_960, # ~18.4 GB
    status: "completed",
    retention_days: 14,
    completed_at: 45.minutes.ago
  },
  {
    app: inventlist,
    provider: "cloudflare_r2",
    bucket_name: "r2-uploads",
    size_bytes: 34_470_666_240, # ~32.1 GB
    status: "completed",
    retention_days: 30,
    completed_at: 2.hours.ago
  },
  {
    server: backup_server,
    provider: "cloudflare_r2",
    bucket_name: "r2-config",
    size_bytes: 440_401_920, # ~420 MB
    status: "warning",
    retention_days: 7,
    completed_at: 12.hours.ago
  }
]

backups.each do |attrs|
  Backup.find_or_create_by!(bucket_name: attrs[:bucket_name]) do |backup|
    backup.assign_attributes(attrs)
  end
end
puts "  Created #{Backup.count} backups"

# Deployments
inventlist_app = App.find_by(name: "InventList")
conductor_app = App.find_by(name: "Conductor")

if inventlist_app && Deployment.count.zero?
  Deployment.create!([
    {
      app: inventlist_app,
      status: "succeeded",
      log: "[12:00:01] Starting deployment for InventList\n[12:00:02] Running: Ensure docker\n[12:00:05] Running: Clone or pull repo\n[12:00:12] Running: Build image\n[12:01:45] Running: Start container\n[12:01:48] Health check passed!\n[12:01:48] Deployment completed successfully!\n",
      started_at: 2.days.ago,
      completed_at: 2.days.ago + 108.seconds
    },
    {
      app: conductor_app,
      status: "succeeded",
      log: "[14:30:01] Starting deployment for Conductor\n[14:30:15] Running: Build image\n[14:31:22] Running: Start container\n[14:31:25] Deployment completed successfully!\n",
      started_at: 1.day.ago,
      completed_at: 1.day.ago + 84.seconds
    }
  ])
  puts "  Created #{Deployment.count} deployments"
end

puts "Done seeding!"

end # unless Rails.env.production?

# ─── Provisioning Scripts (seeded in all environments) ────────────────────────
Script.where(built_in: true).destroy_all

Script.create!([
  {
    name: 'server-provision',
    script_type: 'provision',
    built_in: true,
    description: 'Bootstrap a fresh Ubuntu 22.04 VPS: create deploy user, install Caddy, PostgreSQL, Redis, configure firewall. Run as root.',
    body: <<~'BASH'
      #!/bin/bash
      set -euo pipefail

      APP_NAME="${APP_NAME:-app}"
      DEPLOY_USER="${DEPLOY_USER:-deploy}"

      echo "=== [1/7] System update ==="
      apt-get update -qq && apt-get upgrade -y -qq
      apt-get install -y -qq curl git build-essential libssl-dev libreadline-dev \
        zlib1g-dev libyaml-dev libffi-dev libgmp-dev libpq-dev \
        postgresql postgresql-contrib redis-server ufw

      echo "=== [2/7] Create deploy user ==="
      if ! id "$DEPLOY_USER" &>/dev/null; then
        adduser --disabled-password --gecos "" "$DEPLOY_USER"
        mkdir -p /home/$DEPLOY_USER/.ssh
        [ -f /root/.ssh/authorized_keys ] && \
          cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh/authorized_keys
        chown -R "$DEPLOY_USER:$DEPLOY_USER" /home/$DEPLOY_USER/.ssh
        chmod 700 /home/$DEPLOY_USER/.ssh
        chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys 2>/dev/null || true
      fi

      echo "=== [3/7] Install Caddy ==="
      if ! command -v caddy &>/dev/null; then
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
          | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
          | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq && apt-get install -y -qq caddy
      fi
      systemctl enable caddy && systemctl start caddy

      echo "=== [4/7] Configure PostgreSQL ==="
      systemctl enable postgresql && systemctl start postgresql
      su postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='$DEPLOY_USER'\" | grep -q 1 \
        || psql -c \"CREATE USER $DEPLOY_USER WITH CREATEDB;\""

      echo "=== [5/7] Configure Redis ==="
      systemctl enable redis-server && systemctl start redis-server

      echo "=== [6/7] Firewall ==="
      ufw --force reset
      ufw default deny incoming && ufw default allow outgoing
      ufw allow ssh && ufw allow http && ufw allow https
      ufw --force enable

      echo "=== [7/7] Enable linger for deploy user ==="
      loginctl enable-linger "$DEPLOY_USER"

      echo "Server provisioned. Next: run ruby-install as $DEPLOY_USER."
    BASH
  },
  {
    name: 'ruby-install',
    script_type: 'provision',
    built_in: true,
    description: 'Install ASDF and Ruby for the deploy user. Run as deploy user.',
    body: <<~'BASH'
      #!/bin/bash
      set -euo pipefail

      RUBY_VERSION="${RUBY_VERSION:-3.4.3}"
      ASDF_VERSION="${ASDF_VERSION:-v0.14.1}"

      echo "=== [1/4] Install ASDF ==="
      if [ ! -d "$HOME/.asdf" ]; then
        git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch "$ASDF_VERSION"
      fi

      export ASDF_DIR="$HOME/.asdf"
      . "$HOME/.asdf/asdf.sh"

      grep -q 'asdf.sh' ~/.bashrc || echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc

      echo "=== [2/4] Add Ruby plugin ==="
      asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git 2>/dev/null || true

      echo "=== [3/4] Install Ruby $RUBY_VERSION ==="
      asdf install ruby "$RUBY_VERSION"
      asdf global ruby "$RUBY_VERSION"

      echo "=== [4/4] Install bundler ==="
      gem install bundler --no-document

      ruby --version && bundler --version
      echo "Ruby installed."
    BASH
  },
  {
    name: 'app-setup',
    script_type: 'setup',
    built_in: true,
    description: 'Create app directory structure, clone repo, create shared config. Run as deploy user.',
    body: <<~'BASH'
      #!/bin/bash
      set -euo pipefail

      APP_NAME="${APP_NAME:-app}"
      REPO_URL="${REPO_URL:-}"
      BASE_DIR="${BASE_DIR:-/home/deploy/apps/$APP_NAME}"

      [ -z "$REPO_URL" ] && echo "ERROR: REPO_URL required" && exit 1

      echo "=== [1/4] Create directories ==="
      mkdir -p "$BASE_DIR/releases" "$BASE_DIR/shared/config" \
               "$BASE_DIR/shared/storage" "$BASE_DIR/shared/log" \
               "$BASE_DIR/shared/tmp/pids" "$BASE_DIR/shared/tmp/sockets"

      echo "=== [2/4] Create .env template ==="
      ENVFILE="$BASE_DIR/shared/config/.env"
      if [ ! -f "$ENVFILE" ]; then
        cat > "$ENVFILE" <<EOF
      RAILS_ENV=production
      SECRET_KEY_BASE=changeme_run_rails_secret
      DATABASE_URL=postgres://deploy@localhost/$APP_NAME
      REDIS_URL=redis://localhost:6379/0
      EOF
        echo "Created $ENVFILE — edit before deploying!"
      fi

      echo "=== [3/4] Test repo access ==="
      ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true
      git ls-remote "$REPO_URL" HEAD

      echo "=== [4/4] Initial clone ==="
      RELEASE="$BASE_DIR/releases/$(date +%Y%m%d%H%M%S)"
      git clone --depth 1 "$REPO_URL" "$RELEASE"
      ln -sfn "$RELEASE" "$BASE_DIR/current"

      echo "App directory ready at $BASE_DIR"
    BASH
  },
  {
    name: 'app-deploy',
    script_type: 'deploy',
    built_in: true,
    description: 'Deploy a new release: bundle, migrate, assets, symlink, restart Puma. Run as deploy user.',
    body: <<~'BASH'
      #!/bin/bash
      set -euo pipefail

      APP_NAME="${APP_NAME:-app}"
      REPO_URL="${REPO_URL:-}"
      BASE_DIR="${BASE_DIR:-/home/deploy/apps/$APP_NAME}"
      BRANCH="${BRANCH:-main}"

      . "$HOME/.asdf/asdf.sh"

      TIMESTAMP=$(date +%Y%m%d%H%M%S)
      RELEASE="$BASE_DIR/releases/$TIMESTAMP"
      SHARED="$BASE_DIR/shared"

      echo "=== [1/7] Clone ==="
      git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$RELEASE"
      cd "$RELEASE"
      git rev-parse --short HEAD > REVISION

      echo "=== [2/7] Symlink shared ==="
      ln -sfn "$SHARED/config/.env" "$RELEASE/.env"
      ln -sfn "$SHARED/storage" "$RELEASE/storage"
      ln -sfn "$SHARED/log" "$RELEASE/log"
      ln -sfn "$SHARED/tmp" "$RELEASE/tmp"

      echo "=== [3/7] Bundle ==="
      bundle install --deployment --without development test --jobs 4 --retry 3

      echo "=== [4/7] Assets ==="
      set -a; source "$SHARED/config/.env"; set +a
      bundle exec rails assets:precompile

      echo "=== [5/7] Migrate ==="
      bundle exec rails db:migrate

      echo "=== [6/7] Symlink current ==="
      ln -sfn "$RELEASE" "$BASE_DIR/current"

      echo "=== [7/7] Restart Puma ==="
      systemctl --user restart "$APP_NAME-server" 2>/dev/null || \
        touch "$RELEASE/tmp/restart.txt"

      ls -1dt "$BASE_DIR/releases"/*/ | tail -n +6 | xargs rm -rf 2>/dev/null || true
      echo "Deployed $(cat $BASE_DIR/current/REVISION)"
    BASH
  },
  {
    name: 'systemd-setup',
    script_type: 'setup',
    built_in: true,
    description: 'Write Puma systemd user service, enable linger. Run as deploy user.',
    body: <<~'BASH'
      #!/bin/bash
      set -euo pipefail

      APP_NAME="${APP_NAME:-app}"
      BASE_DIR="${BASE_DIR:-/home/deploy/apps/$APP_NAME}"
      SYSTEMD_DIR="$HOME/.config/systemd/user"

      mkdir -p "$SYSTEMD_DIR"

      cat > "$SYSTEMD_DIR/$APP_NAME-server.service" <<EOF
      [Unit]
      Description=Puma HTTP Server - $APP_NAME
      After=network.target

      [Service]
      Type=simple
      WorkingDirectory=$BASE_DIR/current
      EnvironmentFile=$BASE_DIR/shared/config/.env
      ExecStart=$HOME/.asdf/shims/bundle exec puma -C $BASE_DIR/current/config/puma.rb
      ExecStop=/bin/kill -TSTP \$MAINPID
      Restart=on-failure
      RestartSec=5
      StandardOutput=append:$BASE_DIR/shared/log/puma.log
      StandardError=append:$BASE_DIR/shared/log/puma.error.log

      [Install]
      WantedBy=default.target
      EOF

      systemctl --user daemon-reload
      systemctl --user enable "$APP_NAME-server"
      systemctl --user start  "$APP_NAME-server"
      systemctl --user status "$APP_NAME-server" --no-pager

      echo "Puma service $APP_NAME-server enabled."
    BASH
  }
])

puts "Seeded #{Script.count} scripts"
