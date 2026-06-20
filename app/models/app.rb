class App < ApplicationRecord
  STATUSES = %w[running stopped deploying failed].freeze
  CONTAINER_STATUSES = %w[unknown running exited dead restarting paused].freeze
  DEPLOY_METHODS = %w[docker native kamal].freeze

  belongs_to :organization, optional: true
  belongs_to :server, optional: true
  has_many :backups, dependent: :nullify
  has_many :env_variables, dependent: :destroy
  has_many :deployments, dependent: :destroy
  has_many :databases, dependent: :nullify
  has_many :database_pulls, dependent: :nullify
  has_one :deploy_key, dependent: :destroy

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

  scope :running, -> { where(status: "running") }
  scope :stopped, -> { where(status: "stopped") }
  scope :deploying, -> { where(status: "deploying") }
  scope :failed, -> { where(status: "failed") }
  scope :deployable, -> { joins(:server).where.not(repository_url: [nil, ""]) }

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

  def server_name
    server&.name || "—"
  end

  def deployable?
    server&.ssh_configured? && repository_url.present?
  end

  def last_deployment
    deployments.order(created_at: :desc).first
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
    container_stopped? || status == "failed" || status_check_error.present?
  end

  def can_sync_status?
    (docker? || kamal?) && server&.ssh_configured?
  end

  # The Kamal `service:` name used to label this app's containers on the host
  # (kamal labels them `service=<name>`). Defaults to the slug.
  def kamal_service
    slug
  end

  def status_fresh?
    last_status_check_at.present? && last_status_check_at > 5.minutes.ago
  end

  def status_stale?
    docker? && can_sync_status? && !status_fresh?
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
