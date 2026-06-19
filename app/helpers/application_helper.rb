module ApplicationHelper
  def status_badge(status)
    success = "bg-primary-tint text-primary ring-primary/20"
    warn    = "bg-warning-tint text-warning ring-warning/25"
    danger  = "bg-danger-tint text-danger-deep ring-danger/20"
    info    = "bg-info-tint text-info ring-info/20"
    neutral = "bg-fill text-muted ring-border-strong"

    styles = {
      # Server statuses
      "online" => success,
      "degraded" => warn,
      "offline" => danger,
      # App statuses
      "running" => success,
      "stopped" => neutral,
      "deploying" => info,
      "failed" => danger,
      # Deployment statuses
      "building" => info,
      "succeeded" => success,
      "cancelled" => neutral,
      # Backup statuses
      "completed" => success,
      "pending" => neutral,
      "warning" => warn,
      # Legacy
      "ok" => success,
      "healthy" => success,
      "idle" => neutral
    }

    "inline-flex items-center rounded-pill px-2.5 py-1 text-2xs font-semibold uppercase tracking-label ring-1 ring-inset #{styles.fetch(status, neutral)}"
  end
end
