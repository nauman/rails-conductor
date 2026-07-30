class DashboardController < ApplicationController
  def index
    org = current_organization
    @servers = org.servers.order(:name)
    @apps = org.apps.includes(:server, :deployments).order(:name)
    @backups = org.backups.includes(:server, :app).recent.limit(10)
    @credentials = org.credentials.order(:name)

    # Fleet reads state, not history (spec 08). Apps ordered so the ones needing a
    # decision are first: failing, then never-deployed, then everything else by name.
    # includes(:deployments) keeps deploy_health off the N+1 path.
    @apps_failing = @apps.select(&:deploy_failing?)
    # Parked apps (placeholder / awaiting a calm.page theme) are not gaps — you decided.
    @apps_never_deployed = @apps.select { |a| a.deploy_health.nil? && a.naggable? }
    @dashboard_apps = (@apps_failing + @apps_never_deployed +
                       (@apps - @apps_failing - @apps_never_deployed)).first(10)

    # Still used by the "Deployed Apps" panel below.
    @recent_deployments = Deployment.where(app: org.apps).includes(:app, :user).recent.limit(10)

    @app_health = @apps.index_with { |app| AppHealth.new(app) }

    # Deploy health for the last week, per day: [date, total, failed]. The design shows
    # attempts against failures because the ratio is the story — 29 deploys with 11
    # failures is a different week from 29 clean ones.
    week = Deployment.where(app: org.apps).where("created_at > ?", 7.days.ago)
    by_day = week.group_by { |d| d.created_at.to_date }
    @deploys_7d = (0..6).map { |i| i.days.ago.to_date }.reverse.map do |date|
      day = by_day[date] || []
      [ date, day.size, day.count { |d| d.status == "failed" } ]
    end
    @deploys_week_total = week.size
    @deploys_week_failed = week.count { |d| d.status == "failed" }

    # Issues - what needs attention
    @issues = collect_issues(org, @app_health.values)

    @stats = {
      servers_count: @servers.count,
      servers_online: @servers.online.count,
      servers_degraded: @servers.degraded.count,
      servers_offline: @servers.offline.count,
      apps_count: @apps.count,
      apps_running: @apps.running.count,
      apps_failed: @apps.failed.count,
      apps_stopped: @apps.stopped.count,
      backups_count: @backups.count,
      backups_completed: org.backups.completed.count,
      credentials_count: @credentials.count,
      credentials_active: @credentials.active.count,
      issues_count: @issues.count
    }

    # Kamal/Docker container monitoring stats
    @kamal_stats = {
      total_apps: @apps.count,
      running_apps: @app_health.values.count { |health| health.summary_state == "running" },
      stopped_apps: @app_health.values.count { |health| health.summary_state == "stopped" },
      unknown_status: @app_health.values.count { |health| health.summary_state == "unknown" }
    }
  end

  private

  def collect_issues(org, app_health)
    issues = []

    # Offline servers
    org.servers.offline.each do |server|
      issues << { type: "server", severity: "critical", resource: server, message: "Server is offline" }
    end

    # Degraded servers
    org.servers.degraded.each do |server|
      issues << { type: "server", severity: "warning", resource: server, message: "Server is degraded" }
    end

    org.servers.order(:name).each do |server|
      next unless server.metrics_stale?
      next if server.status == "offline"

      issues << { type: "server", severity: "warning", resource: server, message: "Server metrics are stale" }
    end

    # High CPU servers (>80%)
    org.servers.where("cpu_percent > 80").where("metrics_updated_at > ?", 5.minutes.ago).each do |server|
      issues << { type: "server", severity: "warning", resource: server, message: "High CPU usage (#{server.cpu_percent}%)" }
    end

    # High disk servers (>85%)
    org.servers.where("disk_percent > 85").where("metrics_updated_at > ?", 5.minutes.ago).each do |server|
      issues << { type: "server", severity: "warning", resource: server, message: "High disk usage (#{server.disk_percent}%)" }
    end

    app_health.filter_map(&:incident).each { |incident| issues << incident }

    # Apps whose LATEST deploy failed — one incident per broken app, not one per
    # failure. Listing every failure in a window meant an app that failed twice and
    # then deployed cleanly still showed two criticals, so the list never emptied and
    # stopped being read. A failure a later deploy superseded is history; it lives in
    # the app's activity feed, not here. No time window needed: "still broken" has no
    # expiry, and a break from 30 hours ago is not less broken.
    org.apps.failing_now.includes(:server).each do |app|
      deployment = app.last_deployment
      issues << { type: "deployment", severity: "critical", resource: deployment,
                  message: deployment_failure_message(deployment), action: "deployment" }
    end

    # Capacity imbalance: a box under real strain while another has obvious headroom.
    # This is the argument for app-transfer, and it only means anything when BOTH halves
    # are true — a strained box with nowhere to move to isn't an imbalance, it's a
    # capacity problem, and two idle boxes are just an idle fleet.
    if (imbalance = capacity_imbalance(org))
      strained, roomy = imbalance
      issues << { type: "capacity", severity: "warning", resource: strained,
                  message: "#{strained.name} is out of room (#{strained.cpu_percent}% CPU, " \
                           "#{strained.apps.size} #{'app'.pluralize(strained.apps.size)}) while " \
                           "#{roomy.name} idles at #{roomy.cpu_percent}%",
                  action: "capacity" }
    end

    # Failed backups
    org.backups.where(status: "failed").where("created_at > ?", 7.days.ago).each do |backup|
      issues << { type: "backup", severity: "warning", resource: backup, message: "Backup failed" }
    end

    # A restore that failed is louder than a backup that failed: the dump exists and does
    # not work, which is the case people discover at the worst possible moment.
    org.backups.select(&:alarming?).each do |backup|
      issues << { type: "backup", severity: "critical", resource: backup,
                  message: "Restore test failed — this backup does not work" }
    end

    # Apps with no backup at all. One row for the fleet, not one per app: twelve separate
    # criticals would bury everything else, and the fix is a single button either way.
    # Parked apps are excluded — App.naggable is the same gate the checklist uses.
    unprotected = org.apps.naggable.reject { |app| app.backups.any? }
    if unprotected.any?
      issues << { type: "backup_coverage", severity: "warning", resource: nil,
                  message: "#{unprotected.size} #{'app'.pluralize(unprotected.size)} " \
                           "#{unprotected.one? ? 'has' : 'have'} no backup",
                  action: "protect_all" }
    end

    org.backups.enabled.find_each do |backup|
      next unless backup.dispatch_overdue?

      issues << { type: "backup", severity: "warning", resource: backup, message: "Scheduled backup dispatch is overdue" }
    end

    # Sort by severity (critical first)
    severity_order = { "critical" => 0, "warning" => 1, "info" => 2 }
    issues.sort_by { |i| severity_order[i[:severity]] }
  end

  # A box is "strained" at 60% CPU and "roomy" at 20% with more memory to give. Deliberately
  # a wide gap: a nag that fires on normal variation gets ignored, and moving an app between
  # boxes is expensive enough that it should only be suggested when it's obviously worth it.
  STRAINED_CPU = 60
  ROOMY_CPU = 20

  # Returns [strained, roomy] or nil. Only fresh metrics count — a 90% reading from two
  # hours ago is not evidence about now, and acting on it would move an app for nothing.
  def capacity_imbalance(org)
    fresh = org.servers.where(status: "online").where("metrics_updated_at > ?", 15.minutes.ago).to_a
    return nil if fresh.size < 2

    strained = fresh.select { |s| s.cpu_percent.to_i >= STRAINED_CPU }
                    .max_by { |s| s.cpu_percent.to_i }
    return nil unless strained

    roomy = fresh.select { |s| s.cpu_percent.to_i <= ROOMY_CPU && s.memory_total_mb.to_i > strained.memory_total_mb.to_i }
                 .max_by { |s| s.memory_total_mb.to_i }
    return nil unless roomy

    [ strained, roomy ]
  end

  # Name the kind of failure when we know it, so an operator doesn't go debugging
  # their own migration over a registry outage. Blocked never ran at all — say that
  # rather than "failed", which implies it tried.
  def deployment_failure_message(deployment)
    return "Deploy refused by preflight" if deployment&.status == "blocked"

    case deployment&.cause_class
    when "infrastructure" then "Deployment failed (infrastructure, not app code)"
    when "app_code"       then "Deployment failed (app code)"
    else                       "Deployment failed"
    end
  end
end
