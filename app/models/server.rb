class Server < ApplicationRecord
  PROVIDERS = %w[hetzner digitalocean linode vultr aws gcp azure].freeze
  STATUSES = %w[online degraded offline rebooting].freeze

  # The identity every app-level operation uses. Root is provisioning-only and
  # must be asked for explicitly (see #ssh_user_or_default).
  DEFAULT_SSH_USER = "deploy".freeze

  # How long after a Conductor-initiated reboot we treat the box being unreachable
  # as expected (status stays "rebooting", no offline alert) rather than an outage.
  REBOOT_GRACE = 8.minutes

  belongs_to :organization, optional: true
  belongs_to :ssh_key, optional: true
  has_many :apps, dependent: :nullify
  has_many :backups, dependent: :nullify
  has_many :script_runs, dependent: :destroy
  has_many :database_pulls, dependent: :destroy
  has_many :cron_jobs, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :provider, inclusion: { in: PROVIDERS }, allow_blank: true
  # Defense in depth against cross-tenant key assignment: an attached key must
  # belong to the same org as the server (skipped for legacy null-org records).
  validate :ssh_key_matches_organization

  def ssh_key_matches_organization
    return if ssh_key.nil? || organization_id.nil? || ssh_key.organization_id.nil?
    return if ssh_key.organization_id == organization_id

    errors.add(:ssh_key, "must belong to the same organization as the server")
  end

  scope :online, -> { where(status: "online") }
  scope :degraded, -> { where(status: "degraded") }
  scope :offline, -> { where(status: "offline") }
  scope :recently_seen, -> { where("last_seen_at > ?", 5.minutes.ago) }
  scope :with_ssh, -> { where.not(ssh_key_id: nil).where.not(ip_address: [ nil, "" ]) }

  # Package installs run async; push the result panel to the server page live.
  # Live fleet (spec 08): metrics arrive from a background job, so the dashboard has
  # to be told — otherwise the numbers are only ever as fresh as the last page load,
  # which is exactly what makes people trust `htop` over the control plane.
  after_update_commit :broadcast_dashboard_card, if: :saved_change_to_metrics_updated_at?
  after_update_commit :broadcast_package_install, if: :saved_change_to_last_package_install_at?

  # Persist a ServerAudit rollup so the deploy preflight can read posture without a
  # live SSH probe. Called after any audit run (UI/SSH).
  def record_audit!(status)
    update_columns(last_audit_status: status.to_s, last_audit_at: Time.current)
  end

  def audit_fresh?(within: 7.days) = last_audit_at.present? && last_audit_at > within.ago

  # Store the outcome of a post-reboot recovery pass (RebootRecoveryJob) so the
  # UI/MCP can show what recovery verified + remediated. Internal bookkeeping —
  # skip callbacks/validation like record_audit!.
  def record_recovery!(report)
    update_columns(last_recovery_report: report.to_s, last_recovery_at: Time.current)
  end

  # Honest status for display. A server Conductor has never actually reached
  # (no successful metrics/health check → last_seen_at is nil) reads "pending",
  # not the "online" default stored at registration. Prevents never-connected
  # servers from looking healthy.
  def display_status
    last_seen_at.present? ? status : "pending"
  end

  def ever_seen? = last_seen_at.present?

  def package_install_running? = last_package_install_status == "running"

  def broadcast_dashboard_card
    return unless organization

    broadcast_replace_to(
      organization, :dashboard,
      target: ActionView::RecordIdentifier.dom_id(self, :dashboard_card),
      partial: "dashboard/server_card", locals: { server: self }
    )
  end

  def broadcast_package_install
    broadcast_replace_to(
      self,
      target:  ActionView::RecordIdentifier.dom_id(self, :package_install),
      partial: "servers/package_install",
      locals:  { server: self }
    )
  end

  # OS updates run async too; push the result panel live.
  after_update_commit :broadcast_system_update, if: :saved_change_to_last_update_at?

  def update_running? = last_update_status == "running"

  def broadcast_system_update
    broadcast_replace_to(
      self,
      target:  ActionView::RecordIdentifier.dom_id(self, :system_update),
      partial: "servers/system_update",
      locals:  { server: self }
    )
  end

  def formatted_memory
    return "0 / 0 GB" if memory_total_mb.to_i.zero?
    "#{(memory_used_mb.to_f / 1024).round(1)} / #{(memory_total_mb.to_f / 1024).round} GB"
  end

  def formatted_uptime
    return "—" if uptime_seconds.to_i.zero?

    seconds = uptime_seconds.to_i
    days = (seconds / 86400).to_i
    hours = ((seconds % 86400) / 3600).to_i

    days > 0 ? "#{days}d #{hours}h" : "#{hours}h"
  end

  def cpu_display
    "#{cpu_percent}%"
  end

  def disk_display
    "#{disk_percent}%"
  end

  def ssh_configured?
    ssh_key.present? && ip_address.present?
  end

  # Root is for provisioning only — every app-level operation runs as the deploy
  # user, because root-run commands leave root:root files the container and the
  # deploy user can never write or chown back, and that surfaces at the NEXT
  # deploy. HardenServer asks for root explicitly (the deploy user does not exist
  # yet on a fresh box), so nothing needs an implicit root fallback here.
  def ssh_user_or_default
    ssh_user.presence || DEFAULT_SSH_USER
  end

  def ssh_port_or_default
    ssh_port.presence || 22
  end

  def caddy_admin_port
    caddy_port.presence || 2019
  end

  EDGE_LABELS = { "caddy" => "Caddy", "kamal_proxy" => "kamal-proxy", "other" => "Other", "none" => "None" }.freeze

  # Human label for the detected web edge (what routes :80/:443 on this box).
  def edge_label
    EDGE_LABELS[edge_type] || "Unknown"
  end

  def edge_detected?
    edge_type.present? && edge_type != "unknown"
  end

  def metrics_fresh?
    metrics_updated_at.present? && metrics_updated_at > 5.minutes.ago
  end

  def metrics_stale?
    ssh_configured? && !metrics_fresh?
  end

  # Samples and inventory are different kinds of fact.
  #
  # Utilisation, load, memory-in-use and disk% are SAMPLES — each probe replaces
  # the last. Core count is INVENTORY: it changes only when the machine does, and
  # a probe that failed to read it must not erase what we already knew. Letting a
  # sample overwrite inventory is how a 6-core box comes to report 1.
  def update_metrics!(metrics)
    attrs = {
      cpu_percent: metrics[:cpu_percent],
      memory_used_mb: metrics[:memory_used_mb],
      memory_total_mb: metrics[:memory_total_mb],
      disk_percent: metrics[:disk_percent],
      uptime_seconds: metrics[:uptime_seconds],
      load_average: metrics[:load_average],
      status: "online",
      last_seen_at: Time.current,
      metrics_updated_at: Time.current,
      rebooting_at: nil # the box answered — the reboot window is over
    }
    # Only when this probe actually read it. Absent = unknown = leave it alone.
    attrs[:cpu_cores] = metrics[:cpu_cores] if metrics[:cpu_cores].present?

    update!(attrs)
  end

  # A Conductor-initiated reboot is in flight: show a transitional state and open
  # the grace window so the expected unreachability isn't mistaken for an outage.
  def mark_rebooting!
    update!(status: "rebooting", rebooting_at: Time.current)
  end

  # Within the grace window after a reboot we issued — being unreachable is expected.
  def rebooting_grace? = rebooting_at.present? && rebooting_at > REBOOT_GRACE.ago

  def mark_offline!
    # Don't flip an intentional reboot to "offline" (or alert) while it's still
    # within the expected-down grace window — that's a false alarm.
    return if rebooting_grace?

    was_online = status != "offline"
    update!(status: "offline", last_seen_at: Time.current)

    # Send notification only if transitioning to offline
    AlertMailer.server_offline(self).deliver_later if was_online
  end
end
