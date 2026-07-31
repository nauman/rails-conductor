class App < ApplicationRecord
  include OrganizationConsistency

  STATUSES = %w[running stopped deploying failed].freeze
  CONTAINER_STATUSES = %w[unknown running exited dead restarting paused].freeze
  DEPLOY_METHODS = %w[docker native kamal].freeze
  # App-transfer spec 26 — the two per-app DB axes. Mode is isolation (shared
  # cluster vs dedicated container); placement is locality (the app's own box vs
  # a DB-dedicated host). Both are orthogonal and convertible live.
  DATABASE_MODES = %w[shared dedicated].freeze
  DATABASE_PLACEMENTS = %w[colocated dedicated_host].freeze
  # What YOU have decided about this app, as distinct from what state it happens to be in.
  #   managed           Conductor's to run — the default, and the only one we chase.
  #   unmanaged         running elsewhere and not adopted yet. A real gap; offer adoption.
  #   pending_migration deliberately running until it becomes something else (e.g. a
  #                     calm.page theme). Not a gap — a decision with a finish line.
  #   placeholder       a name and a domain, nothing more. Exclude from everything.
  # Nagging about a decision already made is how a checklist becomes noise.
  INTENTS = %w[managed unmanaged pending_migration placeholder].freeze
  NAGGABLE_INTENTS = %w[managed unmanaged].freeze

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

  # --- DB placement axes (spec 26) -------------------------------------------
  def dedicated_db? = database_mode == "dedicated"
  def shared_db? = database_mode == "shared"
  def colocated_db? = database_placement == "colocated"
  def dedicated_db_host? = database_placement == "dedicated_host"

  # The current cell (mode·placement) — the unit a transfer/conversion moves between.
  def database_cell = "#{database_mode}·#{database_placement}"

  # Canonical names for this app's dedicated Postgres container, volume, and
  # network. Single source of truth so the provisioner (Slice 2) and deploy-time
  # DATABASE_URL injection (Slice 3) agree. Reached by container DNS at
  # `<container>:5432`, so the app and its DB share the network below.
  def dedicated_db_container_name = "#{slug}-db"
  def dedicated_db_volume = "#{slug}-db-data"

  # The Docker network the app's OWN container runs on. A colocated dedicated DB
  # must join this so the app resolves `<app>-db:5432` by container DNS. Kamal 2
  # runs the app (and accessories) on the "kamal" network; overridable via a
  # KAMAL_NETWORK env var. nil for non-Kamal apps — their reachability wiring is
  # not built yet, so the provisioner refuses rather than create an island.
  def deploy_network
    return nil if native? # host-process apps have no docker network
    return env_hash["KAMAL_NETWORK"].presence || "kamal" if kamal?

    # Docker apps also need to join the shared docker network so linked containers
    # (Conductor's shared postgres, kamal-proxy) resolve by name — otherwise the
    # container lands on the default bridge and can't reach conductor-postgres.
    env_hash["DOCKER_NETWORK"].presence || env_hash["KAMAL_NETWORK"].presence || "kamal"
  end

  # The provisioned dedicated database backing this app ON a given server
  # (dedicated mode). Server-scoped because during a transfer the app has a
  # dedicated DB on BOTH the source and target box (same container name), so the
  # box being deployed to picks its own. Only an ACTIVE record is returned — a
  # failed/pending one must never be injected as a live endpoint.
  def dedicated_database(server: self.server)
    return nil unless dedicated_db?

    databases.joins(:database_cluster)
             .where(database_clusters: { container_name: dedicated_db_container_name, server_id: server&.id },
                    status: "active")
             .first
  end

  # Deploy-time env as ordered [key, value] pairs — the single source for what
  # Conductor injects (.kamal/secrets, preflight, generated config). Decision B:
  # a dedicated app's DATABASE_URL is derived from its provisioned DB container at
  # deploy, never baked into the image — UNLESS the operator set DATABASE_URL
  # explicitly, which always wins. `server:` is the box being deployed to (the
  # transfer target, or the app's own server by default).
  def deploy_env_pairs(server: self.server)
    pairs = env_variables.order(:key).map { |v| [ v.key, v.value ] }
    if (url = derived_database_url(server: server))
      pairs << [ "DATABASE_URL", url ]
    end
    pairs.sort_by(&:first)
  end

  # Keys Conductor must declare as Kamal `env.secret` so they're actually
  # injected from .kamal/secrets — operator-secret vars plus any derived secret
  # (the dedicated DATABASE_URL). Without declaring it, a written value is never
  # injected; without treating it as provided, preflight misfires.
  def deploy_secret_keys(server: self.server)
    keys = env_variables.secrets.map(&:key)
    keys << "DATABASE_URL" if derived_database_url(server: server)
    keys.uniq
  end

  # The DATABASE_URL to inject for a dedicated app when the operator hasn't set
  # one explicitly; nil otherwise. Secret — carries the password. Resolved on the
  # box being deployed to (so a transfer's target deploy points at the target DB).
  def derived_database_url(server: self.server)
    return nil unless dedicated_db?
    return nil if env_variables.any? { |v| v.key == "DATABASE_URL" }

    dedicated_database(server: server)&.database_url
  end

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :deploy_method, inclusion: { in: DEPLOY_METHODS }
  validates :database_mode, inclusion: { in: DATABASE_MODES }
  validates :database_placement, inclusion: { in: DATABASE_PLACEMENTS }
  validates :intent, inclusion: { in: INTENTS }
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

  has_many :infra_revisions, dependent: :destroy

  # The choke point is only worth having if it cannot be bypassed. A form field
  # changed outside AppFormChange would leave infra_revision stale — and a
  # revision that lies is worse than none, because residue detection then
  # silently passes. Refuse the save instead.
  validate :form_fields_change_only_through_form_change

  # The only apps a checklist, backup nag or adoption prompt may talk about.
  scope :naggable, -> { where(intent: %w[managed unmanaged]) }

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

  # The path a CI/external deploy POSTs its result to so it becomes a real
  # Deployment row (Q-07-1). Authenticated by the same webhook_secret as the push
  # webhook — see WebhooksController#report_deployment.
  def deployment_report_path
    "/webhooks/#{id}/deployment"
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

  # --- Deploy health (spec 08, slice 1) ---------------------------------------
  #
  # Health is the state of the LATEST deploy, never an accumulation of past ones.
  # Counting history is why the fleet read "11 failures this week" when 8 had
  # already been fixed by the next deploy and only 3 apps were broken — a badge
  # that never clears is a badge people learn to ignore.
  #
  # nil when the app has never deployed through Conductor: "unknown" is a real,
  # different state from "fine", and half this fleet is in it.
  def deploy_health = last_deployment&.status

  # A short label for the intents that need explaining. `managed` is the norm and gets no
  # badge — a badge on every row is a badge nobody reads.
  def intent_label
    case intent
    when "pending_migration" then "pending migration"
    when "placeholder"       then "placeholder"
    when "unmanaged"         then "not adopted"
    end
  end

  # May a checklist, backup nag or adoption prompt talk about this app at all?
  # Distinct from needs_attention? below, which asks "is something wrong right now".
  # A parked decision is neither wrong nor worth chasing.
  def naggable? = NAGGABLE_INTENTS.include?(intent)

  # Currently broken — the last attempt failed, or was refused before it ran.
  # An in-flight deploy is deliberately neither: it hasn't failed yet.
  def deploy_failing? = %w[failed blocked].include?(deploy_health)

  # Why, when we know. nil for older rows that predate cause tracking.
  def deploy_failure_cause = deploy_failing? ? last_deployment&.cause_class : nil

  # Apps whose LATEST deploy failed or was blocked — i.e. what's broken now.
  # Expressed as "no newer deployment exists" rather than by loading every app,
  # so the fleet page stays one query.
  scope :failing_now, -> {
    where(<<~SQL.squish)
      apps.id IN (
        SELECT app_id FROM (
          SELECT DISTINCT ON (app_id) app_id, status
          FROM deployments
          ORDER BY app_id, created_at DESC, id DESC
        ) latest
        WHERE latest.status IN ('failed', 'blocked')
      )
    SQL
  }

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

  # ---- ADR 0004: identity is assigned, never derived -------------------
  #
  # The stable key for every infrastructure artifact this app owns — edge route,
  # container, service label, volume prefix. Derived from the immutable id, NOT
  # from name/slug/deploy_method/role, so it survives a rename, a box move, and
  # a deploy-method switch. `starrrs-web` (kamal service + role) is exactly the
  # form-derived name this replaces.
  def resource_key = "app-#{id}"

  # Has this app ever put anything on a box? Until it has, changing its shape
  # strands nothing.
  #
  # Deployment HISTORY is the durable signal: deployed_at and container_id are
  # both mutable and can be cleared, which would silently reopen the form-change
  # guard on an app that really does have residue out there.
  def ever_deployed?
    deployed_at.present? || container_id.present? || deployments.successful.exists?
  end

  # `<app_id>.<infra_revision>` — which infrastructure shape this app is in.
  # Not a git tag and unrelated to the commit being deployed.
  def infra_identity = "#{id}.#{infra_revision}"

  # Container name for a given release. Carries the revision so residue is
  # detectable by arithmetic: any container whose revision isn't current is
  # stale by definition.
  def release_container_name(sha = nil)
    [ resource_key, "r#{infra_revision}", sha.presence&.first(7) ].compact.join("-")
  end

  # LEGACY name, still live on every box deployed before ADR 0004. Kept for the
  # alias period: Conductor must recognise both until the fleet converges.
  def container_name
    "conductor-#{slug}"
  end

  # Command to tail this app's logs over an SSH exec. Native (classic PaaS-style) apps
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

  # Shell command to run a Rails task on a schedule (cron), resolving where the
  # app actually runs — the kamal/docker container, or native over the user unit.
  # Mirrors log_tail_command's container resolution. `task` is validated by the
  # caller (a bare rake/rails task name, e.g. "slack:sync").
  def scheduled_command(task)
    if native?
      "XDG_RUNTIME_DIR=/run/user/$(id -u) bin/rails #{task}"
    elsif kamal?
      cands = kamal_service_candidates.map { |c| Shellwords.escape(c) }.join(" ")
      %(cid=""; for s in #{cands}; do cid=$(docker ps -q -f "label=service=$s" -f status=running | head -n1); [ -n "$cid" ] && break; done; ) \
        "[ -n \"$cid\" ] && docker exec \"$cid\" bin/rails #{task}"
    else
      "docker exec #{container_name} bin/rails #{task}"
    end
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
    # An app you've parked (placeholder, or running until it becomes a calm.page theme)
    # can't "need attention" — you already decided. Chasing it is how a nag becomes noise.
    return false unless naggable?
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
  # adopted app can have slug "calm-page" but Kamal service "calmpage".
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

  def form_fields_change_only_through_form_change
    return if validation_context == :form_change

    changed = changes.keys & AppFormChange::FORM_FIELDS
    return if changed.empty?
    # The invariant exists to stop a form change stranding residue on a box. An
    # app that has never been deployed has nothing out there to strand, so
    # shaping it before its first deploy is ordinary configuration — not a form
    # change with a history worth recording.
    return if new_record? # creating an app sets these for the first time
    return unless ever_deployed?

    errors.add(:base,
      "#{changed.join(', ')} change an app's infrastructure form — use AppFormChange " \
      "so the revision and its history stay truthful (ADR 0004)")
  end


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
