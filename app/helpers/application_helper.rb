module ApplicationHelper
  # Top-nav pill. Active = solid ink; inactive = muted with a soft hover fill.
  def nav_link(label, path, active:)
    base = "px-3 py-1.5 rounded-pill transition-colors"
    state = active ? "bg-ink text-white" : "text-muted hover:text-ink hover:bg-fill-strong"
    link_to label, path, class: "#{base} #{state}"
  end

  # A top-nav dropdown group. `active:` highlights the trigger when one of the
  # group's pages is open. Yields into the menu; put `nav_menu_link`s there.
  def nav_group(label, active:, &block)
    trigger_state = active ? "bg-ink text-white" : "text-muted hover:text-ink hover:bg-fill-strong"
    tag.div(data: { controller: "dropdown" }, class: "relative") do
      button = tag.button(type: "button", data: { action: "dropdown#toggle" },
        class: "flex items-center gap-1 px-3 py-1.5 rounded-pill transition-colors #{trigger_state}") do
        concat label
        concat tag.span("▾".html_safe, class: "text-[10px] opacity-70")
      end
      menu = tag.div(data: { dropdown_target: "menu" },
        class: "hidden absolute left-0 mt-1.5 w-48 rounded-card border border-border bg-surface p-1 shadow-card z-40",
        &block)
      concat button
      concat menu
    end
  end

  # An item inside a `nav_group` menu.
  def nav_menu_link(label, path, active:)
    state = active ? "bg-fill-strong text-ink" : "text-body hover:bg-fill-strong"
    link_to label, path, class: "block px-3 py-1.5 rounded-control text-sm #{state}"
  end

  # Org role → rui_badge colour. Owner reads as the privileged role (primary),
  # editor as a distinct operating role (info), member as neutral.
  def role_badge_color(role)
    case role.to_s
    when "owner"  then :primary
    when "editor" then :info
    else :slate
    end
  end

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
