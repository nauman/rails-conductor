class App < ApplicationRecord
  include OrganizationConsistency

  STATUSES = %w[running stopped deploying failed].freeze
  CONTAINER_STATUSES = %w[unknown running exited dead restarting paused].freeze
  DEPLOY_METHODS = %w[docker native kamal].freeze

  belongs_to :organization, optional: true
  belongs_to :server, optional: true
  has_many :backups, dependent: :nullify
  has_many :env_variables, dependent: :destroy
  has_many :deployments, dependent: :destroy
  has_many :seed_applications, dependent: :destroy
  has_many :site_checks, dependent: :destroy
  has_many :deploy_checklist_items, -> { order(:position) }, dependent: :destroy
  has_many :databases, dependent: :nullify
  has_many :database_pulls, dependent: :nullify
  has_one :deploy_key, dependent: :destroy

  # Deploy runbook + checklist snapshot for MCP/API/views. Read this before
  # deploying — each app deploys differently.
  def runbook_summary
    items = deploy_checklist_items.to_a
    {
      runbook: deploy_runbook,
      checklist: items.map { |i| { id: i.id, content: i.content, required: i.required, done: i.done } },
      checklist_progress: { done: items.count(&:done?), total: items.size }
    }
  end

  # A valid Postgres identifier base derived from the app, e.g. "calm_page".
  def database_base_name
    raw = (slug.presence || name).to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    raw = "app_#{raw}" unless raw.match?(/\A[a-z_]/)
    raw.presence || "app"
  end

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :deploy_method, inclusion: { in: DEPLOY_METHODS }
  # Only KamalDeployer runs seeds — the flag on a docker/native app would never
  # execute yet would defeat the preflight's failed-seed gate. Enforce here so
  # every path (UI, MCP, direct) obeys, not just the controller.
  validate :seed_flag_kamal_only
  validate_same_organization :server

  def seed_flag_kamal_only
    errors.add(:seed_on_next_deploy, "is only supported for Kamal deploys") if seed_on_next_deploy? && !kamal?
  end

  scope :running, -> { where(status: "running") }
  scope :stopped, -> { where(status: "stopped") }
  scope :deploying, -> { where(status: "deploying") }
  scope :failed, -> { where(status: "failed") }
  scope :deployable, -> { joins(:server).where.not(repository_url: [ nil, "" ]) }
  # The app(s) representing Conductor itself — deploys are reconciled on boot
  # rather than observed inline (see SelfDeployReconciler).
  scope :self_managed, -> { where(self_managed: true) }

  # Live status: when a status-relevant field changes (from a deploy, a status
  # sync, anywhere), push a Turbo Stream that replaces the badge on any open page
  # — no polling, no manual refresh. Subscribe with `turbo_stream_from @app`.
  after_update_commit :broadcast_status_badge, if: :status_relevantly_changed?

  def status_relevantly_changed?
    saved_change_to_status? || saved_change_to_container_status? || saved_change_to_status_check_error?
  end

  def broadcast_status_badge
    broadcast_replace_to self,
      target: ActionView::RecordIdentifier.dom_id(self, :status_badge),
      partial: "apps/status_badge", locals: { app: self }
  end

  # The git sha of the release this Conductor container is running. Kamal injects
  # it as KAMAL_VERSION; absent outside a kamal-deployed container (dev/test).
  def self.current_release_version
    ENV["KAMAL_VERSION"].presence
  end

  # Container status scopes
  scope :container_running, -> { where(container_status: "running") }
  scope :container_stopped, -> { where(container_status: %w[exited dead]) }
  scope :container_unknown, -> { where(container_status: "unknown") }
  scope :healthy, -> { where(container_status: "running", status: "running") }
  scope :unhealthy, -> { where.not(container_status: "running").or(where.not(status: "running")) }
  scope :needs_status_check, -> {
    where(last_status_check_at: nil)
      .or(where("last_status_check_at < ?", 1.minute.ago))
  }
  scope :with_server_ssh, -> { joins(:server).merge(Server.with_ssh) }

  before_validation :generate_slug, on: :create
  before_validation :generate_image_name, on: :create
  before_validation :generate_webhook_secret, on: :create

  # The path SCM providers POST push events to. Combined with webhook_secret,
  # this drives auto-deploy-on-push (see WebhooksController).
  def webhook_path(provider = "github")
    "/webhooks/#{provider}/#{id}"
  end

  def url
    return nil unless domain
    ssl_enabled? ? "https://#{domain}" : "http://#{domain}"
  end

  # Site latency/uptime monitoring — anything with a public URL is monitorable.
  def monitorable? = url.present?
  def latest_site_check = site_checks.recent.first
  def site_status = latest_site_check&.status # :up / :slow / :down / nil
  # Is the site currently served through a CDN/Cloudflare (per the latest check's
  # response headers)? Drives the monitor panel — don't re-recommend Cloudflare when
  # it's already in front.
  def behind_cdn? = latest_site_check&.via_cdn == true

  def server_name
    server&.name || "—"
  end

  def deployable?
    server&.ssh_configured? && repository_url.present?
  end

  def last_deployment
    deployments.order(created_at: :desc).first
  end

  # Single-flight deploy starter shared by every trigger path (MCP, UI, webhook).
  # Guarantees at most one in-flight deployment per app: the unique partial index
  # idx_one_active_deploy_per_app is the real invariant; this returns the existing
  # in-flight deployment instead of racing a second `kamal deploy`. Enqueues the
  # job only for a freshly-created deployment.
  #
  # Runs the deploy preflight (migrations/seeds/audit/threads gate) then dispatches.
  #
  # Returns [deployment, status, preflight] where status is one of:
  #   :started         — a fresh deployment was created + enqueued
  #   :already_running — a deploy was already in flight (deployment is that one)
  #   :blocked         — preflight failed and force was not set (deployment is nil)
  # `preflight` is the DeployPreflight::Result (nil on the already_running race).
  # Pass force: true to deploy past a blocking preflight.
  def start_deployment!(user: nil, force: false, commit_sha: nil)
    existing = deployments.in_progress.order(created_at: :desc).first
    return [ existing, :already_running, nil ] if existing

    preflight = DeployPreflight.new(self).check
    blockers_json = preflight.blocked? ? preflight_blockers_json(preflight) : nil

    if preflight.blocked? && !force
      # Persist the refused attempt (esp. a webhook auto-deploy) so the intent is
      # durable + auditable instead of silently dropped. Not an in_progress state.
      blocked = deployments.create!(user: user, commit_sha: commit_sha,
                                    status: "blocked", preflight_snapshot: blockers_json)
      return [ blocked, :blocked, preflight ]
    end

    # Record a forced override (which blockers it overrode) for the audit trail.
    deployment = deployments.create!(user: user, commit_sha: commit_sha,
                                     forced: force && preflight.blocked?,
                                     preflight_snapshot: force ? blockers_json : nil)
    DeployAppJob.perform_later(deployment.id)
    [ deployment, :started, preflight ]
  rescue ActiveRecord::RecordNotUnique
    # Lost the race: a concurrent trigger created the in-flight deployment first.
    [ deployments.in_progress.order(created_at: :desc).first, :already_running, nil ]
  end

  def preflight_blockers_json(preflight)
    preflight.checks.select { |c| c.status == :fail }
             .map { |c| { key: c.key, label: c.label, detail: c.detail } }.to_json
  end

  def docker?
    deploy_method == "docker"
  end

  def native?
    deploy_method == "native"
  end

  def kamal?
    deploy_method == "kamal"
  end

  # "owner/repo" parsed from the repository URL (https or ssh form), for the
  # GitHub API. Returns nil if it can't be parsed.
  def github_repo
    repository_url.to_s[%r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?\z}, 1]
  end

  def service_name
    "#{slug}-server"
  end

  def app_dir
    "/home/#{server&.ssh_user_or_default || 'deploy'}/apps/#{slug}"
  end

  def container_name
    "conductor-#{slug}"
  end

  # Command to tail this app's logs over an SSH exec. Native (Hatchbox-style) apps
  # run as per-user systemd units named <slug>-server; over a non-login SSH exec
  # `journalctl --user` can't reach the user journal without XDG_RUNTIME_DIR, and
  # stderr would otherwise be dropped — set the runtime dir and fold stderr in so
  # the UI shows the real tail (or the actual error) instead of a blank box.
  def log_tail_command(tail = 300)
    n = [ tail.to_i, 1 ].max
    if native?
      "XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u #{service_name} -n #{n} --no-pager 2>&1"
    elsif kamal?
      kamal_log_command(n)
    else
      "docker logs --tail #{n} #{container_name} 2>&1"
    end
  end

  # Kamal names its own containers (<service>-<role>-<version>) — never
  # conductor-<slug> — and the `service` label isn't always the slug (an adopted
  # app with slug "calm-page" can run as service "calmpage"). So resolve the
  # running container by matching any service candidate against the label — the
  # same lookup ContainerStatus uses — instead of guessing a fixed name.
  def kamal_log_command(n)
    cands = kamal_service_candidates.map { |c| Shellwords.escape(c) }.join(" ")
    names = kamal_service_candidates.join(", ")
    %(cid=""; for s in #{cands}; do cid=$(docker ps -q -f "label=service=$s" -f status=running | head -n1); [ -n "$cid" ] && break; done; ) \
      "if [ -n \"$cid\" ]; then docker logs --tail #{n} \"$cid\" 2>&1; " \
      "else echo \"No running container found (service: #{names}) on this host\"; fi"
  end

  # Human label for the log source, matching what log_tail_command actually reads.
  def log_source_label
    if native?
      "journalctl --user -u #{service_name}"
    elsif kamal?
      "docker logs (service: #{kamal_service})"
    else
      "docker logs #{container_name}"
    end
  end

  def env_hash
    env_variables.each_with_object({}) { |var, hash| hash[var.key] = var.value }
  end

  def container_running?
    container_status == "running"
  end

  def container_stopped?
    %w[exited dead].include?(container_status)
  end

  def needs_attention?
    return true if status == "failed" || status_check_error.present?

    # A stopped container only warrants attention if the app is meant to be
    # running — a deliberately-stopped app sitting exited is healthy.
    status != "stopped" && container_stopped?
  end

  def can_sync_status?
    status_sync_supported? && server&.ssh_configured?
  end

  def status_sync_supported?
    docker? || kamal?
  end

  def restart_supported?
    server&.ssh_configured? && (docker? || kamal? || native?)
  end

  def dashboard_restart_supported?
    restart_supported? && status_sync_supported?
  end

  # The Kamal `service:` name used to label this app's containers on the host
  # (kamal labels them `service=<name>`). Defaults to the slug.
  def kamal_service
    slug
  end

  # The service label on a running container doesn't always equal the slug: an
  # adopted/Hatchbox app can have slug "calm-page" but Kamal service "calmpage".
  # Match on the slug AND a separator-stripped variant so status sync finds it.
  def kamal_service_candidates
    [ kamal_service, kamal_service.gsub(/[^a-z0-9]/i, "").downcase ].uniq
  end

  def status_fresh?
    last_status_check_at.present? && last_status_check_at > 5.minutes.ago
  end

  def status_stale?
    can_sync_status? && !status_fresh?
  end

  def update_container_status!(new_status, error: nil, started_at: nil)
    attrs = {
      container_status: new_status,
      last_status_check_at: Time.current,
      status_check_error: error
    }
    attrs[:container_started_at] = started_at if started_at
    update!(attrs)
  end

  private

  def generate_slug
    return if slug.present?
    self.slug = name.to_s.parameterize
  end

  def generate_image_name
    return if image_name.present?
    self.image_name = "conductor/#{slug}"
  end

  def generate_webhook_secret
    self.webhook_secret = SecureRandom.hex(32) if webhook_secret.blank?
  end
end
