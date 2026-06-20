class Server < ApplicationRecord
  PROVIDERS = %w[hetzner digitalocean linode vultr aws gcp azure].freeze
  STATUSES = %w[online degraded offline].freeze

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

  scope :online, -> { where(status: "online") }
  scope :degraded, -> { where(status: "degraded") }
  scope :offline, -> { where(status: "offline") }
  scope :recently_seen, -> { where("last_seen_at > ?", 5.minutes.ago) }
  scope :with_ssh, -> { where.not(ssh_key_id: nil).where.not(ip_address: [nil, ""]) }

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

  def ssh_user_or_default
    ssh_user.presence || "root"
  end

  def ssh_port_or_default
    ssh_port.presence || 22
  end

  def caddy_admin_port
    caddy_port.presence || 2019
  end

  def metrics_fresh?
    metrics_updated_at.present? && metrics_updated_at > 5.minutes.ago
  end

  def metrics_stale?
    ssh_configured? && !metrics_fresh?
  end

  def update_metrics!(metrics)
    update!(
      cpu_percent: metrics[:cpu_percent],
      memory_used_mb: metrics[:memory_used_mb],
      memory_total_mb: metrics[:memory_total_mb],
      disk_percent: metrics[:disk_percent],
      uptime_seconds: metrics[:uptime_seconds],
      status: "online",
      last_seen_at: Time.current,
      metrics_updated_at: Time.current
    )
  end

  def mark_offline!
    was_online = status != "offline"
    update!(status: "offline", last_seen_at: Time.current)

    # Send notification only if transitioning to offline
    AlertMailer.server_offline(self).deliver_later if was_online
  end
end
