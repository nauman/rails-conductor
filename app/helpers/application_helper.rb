module ApplicationHelper
  def status_badge(status)
    styles = {
      # Server statuses
      "online" => "bg-emerald-50 text-emerald-700 ring-emerald-200",
      "degraded" => "bg-amber-50 text-amber-700 ring-amber-200",
      "offline" => "bg-rose-50 text-rose-700 ring-rose-200",
      # App statuses
      "running" => "bg-emerald-50 text-emerald-700 ring-emerald-200",
      "stopped" => "bg-slate-100 text-slate-600 ring-slate-200",
      "deploying" => "bg-blue-50 text-blue-700 ring-blue-200",
      "failed" => "bg-rose-50 text-rose-700 ring-rose-200",
      # Deployment statuses
      "building" => "bg-blue-50 text-blue-700 ring-blue-200",
      "succeeded" => "bg-emerald-50 text-emerald-700 ring-emerald-200",
      "cancelled" => "bg-slate-100 text-slate-600 ring-slate-200",
      # Backup statuses
      "completed" => "bg-emerald-50 text-emerald-700 ring-emerald-200",
      "pending" => "bg-slate-100 text-slate-600 ring-slate-200",
      "warning" => "bg-amber-50 text-amber-700 ring-amber-200",
      # Legacy
      "ok" => "bg-emerald-50 text-emerald-700 ring-emerald-200",
      "healthy" => "bg-emerald-50 text-emerald-700 ring-emerald-200",
      "idle" => "bg-slate-100 text-slate-600 ring-slate-200"
    }

    "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ring-inset #{styles.fetch(status, "bg-slate-100 text-slate-600 ring-slate-200")}"
  end
end
