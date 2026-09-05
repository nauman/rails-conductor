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
  #                     my-app.com theme). Not a gap — a decision with a finish line.
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
  # Legacy rows remain for the historical backfill and rollback audit. Product
  # writes go through AppRunbook and Jazari; this association is not a source of truth.
  has_many :deploy_checklist_items, -> { order(:position) }, dependent: :destroy
  has_many :databases, dependent: :nullify
  has_many :database_pulls, dependent: :nullify
  has_one :deploy_key, dependent: :destroy

  # Deploy runbook + checklist snapshot for MCP/API/views. Read this before
  # deploying — each app deploys differently.
  # Does the build run on a machine that is also serving traffic? True for the
  # docker path (docker build over SSH on the target, always) and for a kamal app
  # whose repo sets `builder.remote`. Conductor does not choose this — kamal reads
  # it from the app's own config — so the honest answer comes from what the last
  # deploy RECORDED, and is nil until one has.
  def builds_on_a_serving_box?
    return nil if build_host.blank?

    build_host != KamalDeployer::CONTROL_MACHINE
  end

  # A sentence for a human, or nil when there is no image to build.
  def build_location_summary
    return nil if deploy_method.to_s == "native"
    return "not recorded yet — the next deploy will report it" if build_host.blank?
    return "control machine (built by Conductor, pushed to the registry; the target pulls)" unless builds_on_a_serving_box?

    "#{build_host} — this build runs on a server, competing with whatever it serves"
  end

  def runbook_summary
    AppRunbook.new(self).summary
  end

  # A valid Postgres identifier base derived from the app, e.g. "calm_page".
  # THE DATABASE NAMING CONVENTION, in one place because it was previously in two.
  #
  # The UI derived `<base>_production` / `<base>` from the app; the MCP tool took a
  # caller-supplied name and username with no default. So the path most likely to
  # provision a brand-new app — an agent — had no convention at all, and named
  # databases by hand. A convention only one caller follows is a preference.
  #
  # These names reach `CREATE DATABASE` and `CREATE ROLE` as interpolated SQL, so the
  # derivation has to produce a legal identifier BY CONSTRUCTION, not by luck:
  # everything outside [a-z0-9_] collapses to an underscore, and a leading digit is
  # prefixed because postgres will not accept one unquoted.
  # Postgres truncates identifiers at 63 bytes, so the suffix has to fit inside the
  # budget rather than be appended past it — otherwise a long slug silently loses
  # `_production` and two apps collide on a name neither of them chose.
  MAX_IDENTIFIER_BYTES = 63
  DATABASE_SUFFIX = "_production".freeze
  BASE_NAME_LIMIT = MAX_IDENTIFIER_BYTES - DATABASE_SUFFIX.bytesize

  # Names the derivation must not CHOOSE: postgres owns them, or they would need
  # quoting to survive interpolation. Deliberately NOT a general-purpose blocklist —
  # `users`, `admin` and `root` are legal identifiers and an app may have them.
  #
  # `conductor` is here for a different reason than the rest: it is the admin role
  # DedicatedDbProvisioner creates on every cluster it stands up. The client checks
  # that contextually against the actual cluster, which is the correct check — but
  # the derivation runs before a cluster is chosen, so avoiding the default here
  # turns a provisioning failure into a name that just works.
  UNAVAILABLE_BASE_NAMES = (
    PostgresClusterClient::UNUSABLE_IDENTIFIERS + PostgresClusterClient::RESERVED_WORDS +
    [ DedicatedDbProvisioner::ADMIN_USERNAME ]
  ).freeze

  # NOT MEMOIZED. The result depends on this app's slug, name and id AND on every
  # older sibling's normalized name — so any cache key short of "the whole
  # organization" is a stale-derivation bug waiting to happen, which is the exact
  # class of defect this work exists to remove. The scan is one query on a small
  # table, and it runs when provisioning, not on the deploy path.
  # Set rather than demanded: a caller should not have to know the rule to satisfy
  # it. The validation exists for the case someone turns it off on purpose.
  def adopt_kamal_contract
    self.self_describing = true if kamal? && (new_record? || will_save_change_to_deploy_method?)
  end

  def kamal_apps_are_self_describing
    return if self_describing?

    errors.add(:self_describing,
               "must be true for a kamal app — Conductor generates its deploy overlay and " \
               "git-safe secrets pointers (ADR 0001/0003). Turning it off writes raw secret " \
               "values into .kamal/secrets instead.")
  end

  def database_base_name
    derived_database_base_name || assigned_database_base_name
  end

  # The database and role an app gets when Conductor provisions for it. Callers use
  # these rather than composing their own, so every path agrees.
  #
  # ONCE A DATABASE EXISTS, THE RECORD IS THE FACT AND THE DERIVATION IS SPENT
  # (ADR 0010). Re-deriving after a slug edit — or after this list of unavailable
  # names grows — would aim a re-provision at a NEW, empty database while the app's
  # data stayed in the old one, and nothing would report an error.
  # SERVER-SCOPED, like #dedicated_database and for the same reason: during a
  # transfer an app has a database on the source AND one on the target, and the
  # question "what is this app's database called" only has an answer once you say
  # where. An unscoped lookup would answer with the source while provisioning the
  # target.
  def database_name(server: self.server)
    provisioned_database(server: server)&.name || "#{database_base_name}#{DATABASE_SUFFIX}"
  end

  def database_username(server: self.server)
    provisioned_database(server: server)&.username || database_base_name
  end

  # ONE active database means there is nothing to disambiguate, wherever it lives —
  # a shared cluster on a separate DB host is the ordinary case, and scoping it away
  # made the app's own database invisible, so a rename re-derived a NEW name.
  # The server only decides between several, which is the transfer case it exists for.
  def provisioned_database(server: self.server)
    actives = databases.includes(:database_cluster).select { |d| d.status == "active" }
    return actives.first if actives.one?

    actives.select { |d| d.database_cluster&.server_id == server&.id }.min_by(&:id)
  end

  # `app_<id>` in the spirit of ADR 0004: when a name cannot be trusted to be legal
  # or unique, stop deriving and use the identity that was assigned.
  def assigned_database_base_name = "app_#{id}"

  # nil means "the derived name is not usable" — reserved, empty, or already claimed
  # by an older app. Every one of those is a case where deriving harder would only
  # produce a name that looks right and points at someone else's database.
  def derived_database_base_name
    raw = normalized_database_base_name
    return nil if raw.blank? || UNAVAILABLE_BASE_NAMES.include?(raw)
    return nil unless id # nothing to fall back to yet, and nothing to collide with
    return nil if database_base_name_claimed_by_older_app?(raw)

    raw
  end

  # `app_<digits>` is the assigned namespace. A slug of `app-102` normalizes into it
  # and would squat on app 102's fallback, so a derivation that lands there is
  # treated as unusable — the app takes its OWN assigned name, which is unique by
  # construction. A fallback that can be derived is not a fallback.
  ASSIGNED_NAMESPACE = /\Aapp_\d+\z/

  def normalized_database_base_name
    raw = (slug.presence || name).to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    raw = "app_#{raw}" if raw.present? && !raw.match?(/\A[a-z_]/)
    return nil if raw.match?(ASSIGNED_NAMESPACE)
    # Truncating alone would manufacture the collision this method exists to avoid,
    # so a shortened name carries the assigned id and stops being a pure derivation.
    return raw if raw.bytesize <= BASE_NAME_LIMIT

    suffix = "_#{id}"
    raw.byteslice(0, BASE_NAME_LIMIT - suffix.bytesize).sub(/_+\z/, "") + suffix
  end

  # Distinct slugs collapse to one base — `foo-bar`, `foo_bar` and `foo.bar` all
  # become `foo_bar`. The older app keeps the plain name so its database never moves
  # under it; the newcomer is the one that gives way.
  # Set rather than demanded: a caller should not have to know the rule to satisfy
  # it. The validation exists for the case someone turns it off on purpose.
  def adopt_kamal_contract
    self.self_describing = true if kamal? && (new_record? || will_save_change_to_deploy_method?)
  end

  def kamal_apps_are_self_describing
    return if self_describing?

    errors.add(:self_describing,
               "must be true for a kamal app — Conductor generates its deploy overlay and " \
               "git-safe secrets pointers (ADR 0001/0003). Turning it off writes raw secret " \
               "values into .kamal/secrets instead.")
  end

  def database_base_name_claimed_by_older_app?(raw)
    return false unless organization # nothing to collide with, and never a crash

    organization.apps.where.not(id: id).where(id: ...id)
                .any? { |other| other.normalized_database_base_name == raw }
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
  # --- resource names, during ADR 0004's alias period --------------------
  #
  # `uses_stable_names` decides what NEW resources are called. It is per-app and
  # never flipped automatically, because these name LIVE infrastructure: a
  # systemd unit that is running, a DB container holding data, a volume. Changing
  # the derivation under a running app orphans all of it — the exact residue
  # problem the stable key exists to end.
  #
  # Lookups use the *_candidates methods, which accept both names, so Conductor
  # finds a resource whichever era it was created in.
  def dedicated_db_container_name = uses_stable_names? ? "#{resource_key}-db" : "#{slug}-db"
  def dedicated_db_volume         = uses_stable_names? ? "#{resource_key}-db-data" : "#{slug}-db-data"

  # Both spellings, stable first. Use these to FIND things; use the singular
  # methods to NAME new things.
  def dedicated_db_container_candidates = [ "#{resource_key}-db", "#{slug}-db" ].uniq
  def dedicated_db_volume_candidates    = [ "#{resource_key}-db-data", "#{slug}-db-data" ].uniq
  def service_name_candidates           = [ "#{resource_key}-server", "#{slug}-server" ].uniq

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

  # The port stored on an app is the HOST port published to Caddy/direct
  # traffic. It is not necessarily the port the process listens on inside the
  # container (an app is 9080 -> 3000). Rails defaults to 3000; apps with a
  # different internal listener declare PORT explicitly in their deploy env.
  def runtime_port
    configured = Integer(env_hash["PORT"], exception: false)
    configured&.between?(1, 65_535) ? configured : 3000
  end

  # A host-published port is an explicit infrastructure coordinate. It must
  # never inherit the process's internal listener: Caddy cannot reach a
  # container-only port, and guessing here can repoint a healthy route to an
  # unused host port.
  def published_port = port.presence

  # The provisioned dedicated database backing this app ON a given server
  # (dedicated mode). Server-scoped because during a transfer the app has a
  # dedicated DB on BOTH the source and target box (same container name), so the
  # box being deployed to picks its own. Only an ACTIVE record is returned — a
  # failed/pending one must never be injected as a live endpoint.
  def dedicated_database(server: self.server)
    return nil unless dedicated_db?

    databases.joins(:database_cluster)
             .where(database_clusters: { container_name: dedicated_db_container_candidates, server_id: server&.id },
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
  # The slug reaches SHELL COMMANDS on fleet servers (container names, systemd
  # units, directory paths), so its character set is a security boundary, not a
  # cosmetic rule. Interpolation sites escape as well — this is the first of two
  # defences, not the only one.
  validates :slug, presence: true, uniqueness: true,
            format: { with: /\A[a-z0-9][a-z0-9._-]*\z/,
                      message: "may contain only lowercase letters, digits, dots, dashes and underscores" }
  validates :status, inclusion: { in: STATUSES }
  validates :deploy_method, inclusion: { in: DEPLOY_METHODS }
  # ADR 0003: one deploy path, and Kamal is the contract. A kamal app that is not
  # self-describing does not honour it — Conductor writes `.kamal/secrets` with raw
  # values instead of the generated overlay and git-safe pointers, so marking a
  # variable sensitive buys nothing on the one path where it could mean something.
  #
  # Enforced on CHANGE, not on every save: eight apps predate this rule and flipping
  # their generated config all at once is a change nobody is watching. They stay
  # valid, `rake kamal:self_describing_audit` lists them, and each is migrated with
  # someone looking. What is refused is going backwards, or arriving non-compliant.
  validate :kamal_apps_are_self_describing, if: -> { kamal? && will_save_change_to_self_describing? || (kamal? && new_record?) }

  # These all reach REMOTE SHELL COMMANDS on fleet servers (git clone, docker
  # build, curl). Deploy-path interpolation escapes them, but validating the
  # shape here means a hostile value never reaches storage in the first place —
  # and escaping alone is one forgotten interpolation away from failing.
  validates :branch, format: { with: /\A[\w.\-\/]+\z/, message: "may contain only letters, digits, dot, dash, underscore and slash" },
            allow_blank: true
  validates :repository_url, format: { with: %r{\A(https://|git@)[\w.@:/~\-]+\z}, message: "must be an https:// or git@ URL" },
            allow_blank: true
  validates :dockerfile_path, format: { with: %r{\A[\w.\-/]+\z}, message: "may contain only letters, digits, dot, dash, underscore and slash" },
            allow_blank: true
  validates :image_name, format: { with: %r{\A[a-z0-9][a-z0-9._\-/]*\z}, message: "may contain only lowercase letters, digits, dot, dash, underscore and slash" },
            allow_blank: true
  validates :health_check_path, format: { with: %r{\A/[\w.\-/]*\z}, message: "must be a path starting with /" },
            allow_blank: true
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

  before_validation :adopt_kamal_contract
  before_validation :adopt_stable_names, on: :create
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

  def maintenance? = maintenance_mode?
  # How many of the most recent checks were `up` only because the retry passed.
  # A flapping host is serving, so it is never site_down — this is the signal that
  # keeps it visible anyway (codex review R-1).
  RETRY_RECOVERY_WINDOW = 6

  def recent_retry_recoveries
    site_checks.recent.limit(RETRY_RECOVERY_WINDOW).count(&:recovered_on_retry?)
  end

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
    if FleetCanon.shape_for(self)[:driver] == "external"
      policy = DeployPreflight::Result.new(checks: [
        DeployPreflight::Check.new(
          key: :deploy_policy,
          label: "Deploy policy",
          status: :fail,
          detail: "This app is externally deployed; Jazari/agents must not run kamal deploy."
        )
      ])
      blocked = deployments.create!(user: user, commit_sha: commit_sha,
                                    deploy_method: deploy_method, infra_revision: infra_revision,
                                    status: "blocked",
                                    preflight_snapshot: preflight_blockers_json(policy))
      return [ blocked, :blocked, policy ]
    end

    existing = deployments.in_progress.order(created_at: :desc).first
    return [ existing, :already_running, nil ] if existing

    preflight = DeployPreflight.new(self).check
    blockers_json = preflight.blocked? ? preflight_blockers_json(preflight) : nil

    if preflight.blocked? && !force
      # Persist the refused attempt (esp. a webhook auto-deploy) so the intent is
      # durable + auditable instead of silently dropped. Not an in_progress state.
      blocked = deployments.create!(user: user, commit_sha: commit_sha,
                                    deploy_method: deploy_method, infra_revision: infra_revision,
                                    status: "blocked", preflight_snapshot: blockers_json)
      return [ blocked, :blocked, preflight ]
    end

    # Record a forced override (which blockers it overrode) for the audit trail.
    # Stamp the FORM this ships under, so a later rollback can tell whether the
    # release is still a valid target for the app as it is now.
    deployment = deployments.create!(user: user, commit_sha: commit_sha,
                                     deploy_method: deploy_method, infra_revision: infra_revision,
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
    uses_stable_names? ? "#{resource_key}-server" : "#{slug}-server"
  end

  def app_dir
    "/home/#{server&.ssh_user_or_default || 'deploy'}/apps/#{slug}"
  end

  # ---- ADR 0004: identity is assigned, never derived -------------------
  #
  # The stable key for every infrastructure artifact this app owns — edge route,
  # container, service label, volume prefix. Derived from the immutable id, NOT
  # from name/slug/deploy_method/role, so it survives a rename, a box move, and
  # a deploy-method switch. `myapp-web` (kamal service + role) is exactly the
  # form-derived name this replaces.
  def resource_key = "app-#{id}"

  # Residue from a previous form, read from the STORED rollup (ResidueCheckJob).
  # Never probes — callers on a request path must stay fast.
  def residue
    (residue_findings || []).map(&:symbolize_keys)
  end

  def residue? = residue.any?

  # A result nobody has refreshed in a while should not be presented as current.
  def residue_stale?
    residue_checked_at.nil? || residue_checked_at < ResidueCheckJob::STALE_AFTER.ago
  end

  # Whether Conductor's record of this app's release matches the box, from the
  # STORED rollup (ReleaseDriftCheckJob). Never probes.
  def release_state = (self[:release_state] || {}).symbolize_keys

  # `unknown` is included deliberately. The detector fails closed and records
  # "I could not tell" — but if the worklist then stays silent about it, the
  # system as a whole fails OPEN: an unreachable box or a mutable `:latest` tag
  # produces no signal at all, which reads exactly like agreement.
  RELEASE_ATTENTION = %w[drift unrecorded mixed_release unknown].freeze

  def release_drift? = RELEASE_ATTENTION.include?(release_state[:status])

  def release_state_stale?
    release_checked_at.nil? || release_checked_at < ReleaseDriftCheckJob::STALE_AFTER.ago
  end

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

  # Container name for a given deployment. Carries the revision so residue is
  # detectable by arithmetic, plus the deployment id so a same-commit config
  # redeploy can boot beside the currently-serving container. The release SHA
  # alone is not unique when env, edge, or other runtime config changes.
  def release_container_name(sha = nil, deployment_id: nil)
    deployment = "d#{deployment_id}" if deployment_id
    [ resource_key, "r#{infra_revision}", deployment, sha.presence&.first(7) ].compact.join("-")
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
  # Shell that resolves the app's LIVE container id into $cid, by service label
  # with the legacy fixed name as a fallback.
  #
  # A fixed name stopped being reliable for docker apps once a zero-downtime
  # deploy started running them as app-<id>-r<rev>-<sha> (ADR 0003) — `docker
  # logs conductor-<slug>` would simply find nothing. Every container Conductor
  # starts carries service=<resource_key>, so one lookup covers every form.
  # `strict:` decides whether PREVIOUS-FORM containers are acceptable answers.
  #
  #   strict: true  (default) — only this app's CURRENT form. Used where the
  #     command runs INSIDE the container: logs, exec, cron, the runner. Falling
  #     through to a Kamal-era container there means executing against the
  #     previous release — the wrong code, silently, with the right exit status.
  #   strict: false — anything wearing this app's identity, current or not. Used
  #     where the goal is to ACT ON whatever is there: stop, restart, cleanup.
  def resolve_container_shell(status: "running", strict: true)
    keys = [ resource_key ]
    keys += kamal_service_candidates if kamal? || !strict
    cands = keys.uniq.map { |c| Shellwords.escape(c) }.join(" ")
    status_flag = status.present? ? %( -f status=#{status}) : ""

    # The stable key is shared by EVERY revision of this app, so matching it
    # alone can still select a container from a previous shape. Under strict,
    # narrow to the current revision first — that is the difference between
    # "this app" and "this app as it is now", and running a console or a cron
    # task inside a stale release is the failure this exists to prevent.
    revision_first =
      if strict
        current = %(-f "label=service=#{Shellwords.escape(resource_key)}" ) +
                  %(-f "label=conductor.infra_revision=#{infra_revision}")
        %(cid=$(docker ps -q #{current}#{status_flag} | head -n1); )
      else
        %(cid=""; )
      end

    revision_first +
      %(if [ -z "$cid" ]; then for s in #{cands}; do cid=$(docker ps -q -f "label=service=$s"#{status_flag} | head -n1); [ -n "$cid" ] && break; done; fi; ) +
      %(if [ -z "$cid" ]; then cid=$(docker ps -q -f "name=^/#{Shellwords.escape(container_name)}$"#{status_flag} | head -n1); fi; )
  end

  def log_tail_command(tail = 300)
    n = [ tail.to_i, 1 ].max
    if native?
      "XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u #{service_name} -n #{n} --no-pager 2>&1"
    elsif kamal?
      kamal_log_command(n)
    else
      resolve_container_shell + %([ -n "$cid" ] && docker logs --tail #{n} "$cid" 2>&1 || echo "no running container")
    end
  end

  # Kamal names its own containers (<service>-<role>-<version>) — never
  # conductor-<slug> — and the `service` label isn't always the slug (an adopted
  # app with slug "my-app" can run as service "myapp"). So resolve the
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
      resolve_container_shell + %([ -n "$cid" ] && docker exec "$cid" bin/rails #{task})
    end
  end

  # Human label for the log source, matching what log_tail_command actually reads.
  def log_source_label
    if native?
      "journalctl --user -u #{service_name}"
    elsif kamal?
      "docker logs (service: #{kamal_service})"
    else
      "docker logs (service: #{resource_key})"
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
    # An app you've parked (placeholder, or running until it becomes a my-app.com theme)
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
  # adopted app can have slug "my-app" but Kamal service "myapp".
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


  # An app created from now on has no live infrastructure, so it can use the
  # stable key from the start. Existing apps keep their legacy names until an
  # operator migrates them deliberately.
  def adopt_stable_names
    self.uses_stable_names = true if new_record?
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
