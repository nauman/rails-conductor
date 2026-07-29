module AppsHelper
  # One badge for "how did this app's last deploy go", used by the dashboard, the
  # apps list and the app page so the three can't drift apart (spec 08, slice 1).
  #
  # Reads App#deploy_health — the LATEST deploy's status, never an accumulation.
  # Six states, and each one says something different:
  #
  #   nil        never deployed through Conductor. Not "fine": five of twelve apps
  #              are here, and the honest label invites you to connect them.
  #   succeeded  green, regardless of how many earlier deploys failed.
  #   failed     with the cause when we know it — "not your code" saves someone an
  #              hour debugging a migration over a registry outage.
  #   blocked    refused by preflight; it never ran, so don't say "failed".
  #   otherwise  in flight (pending/building/deploying) — not yet a failure.
  def deploy_health_badge(app)
    # Intent first: "not deployed here" on an app you deliberately parked reads as an
    # accusation. What you decided outranks what the deploy log happens to say.
    if (label = app.intent_label) && app.deploy_health.nil?
      return rui_badge(text: label, color: app.intent == "unmanaged" ? :warning : :slate)
    end

    case app.deploy_health
    when nil          then rui_badge(text: "not deployed here", color: :slate)
    when "succeeded"  then rui_badge(text: "deployed", color: :success)
    when "blocked"    then rui_badge(text: "refused by preflight", color: :warning)
    when "failed"     then rui_badge(text: deploy_failure_label(app), color: :danger)
    when "cancelled"  then rui_badge(text: "cancelled", color: :slate)
    else                   rui_badge(text: app.deploy_health, color: :info)
    end
  end

  def deploy_failure_label(app)
    case app.deploy_failure_cause
    when "infrastructure" then "failed · not app code"
    when "app_code"       then "failed · app code"
    else                       "failed"
    end
  end
end
