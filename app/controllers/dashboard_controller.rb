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
    @apps_by_server = @apps.includes(:server).group_by(&:server)
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

    # Failed backups
    org.backups.where(status: "failed").where("created_at > ?", 7.days.ago).each do |backup|
      issues << { type: "backup", severity: "warning", resource: backup, message: "Backup failed" }
    end

    org.backups.enabled.find_each do |backup|
      next unless backup.dispatch_overdue?

      issues << { type: "backup", severity: "warning", resource: backup, message: "Scheduled backup dispatch is overdue" }
    end

    # Sort by severity (critical first)
    severity_order = { "critical" => 0, "warning" => 1, "info" => 2 }
    issues.sort_by { |i| severity_order[i[:severity]] }
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
