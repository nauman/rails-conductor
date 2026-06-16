class DashboardController < ApplicationController
  def index
    org = current_organization
    @servers = org.servers.order(:name)
    @apps = org.apps.includes(:server).order(:name)
    @backups = org.backups.includes(:server, :app).recent.limit(10)
    @credentials = org.credentials.order(:name)

    # Recent deployments (last 10) for this org's apps
    @recent_deployments = Deployment.where(app: org.apps).includes(:app, :user).recent.limit(10)

    # Issues - what needs attention
    @issues = collect_issues(org)

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
      running_apps: @apps.container_running.count,
      stopped_apps: @apps.container_stopped.count,
      unknown_status: @apps.container_unknown.count
    }
    @apps_by_server = @apps.includes(:server).group_by(&:server)
  end

  private

  def collect_issues(org)
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

    org.apps.includes(:server).order(:name).each do |app|
      next unless app.status_stale?

      issues << { type: "app", severity: "warning", resource: app, message: "Container status is stale" }
    end

    # Failed apps
    org.apps.failed.includes(:server).each do |app|
      issues << { type: "app", severity: "critical", resource: app, message: "App deployment failed" }
    end

    # Stopped apps (might be intentional, but worth noting)
    org.apps.stopped.includes(:server).each do |app|
      issues << { type: "app", severity: "info", resource: app, message: "App is stopped" }
    end

    # Failed deployments in last 24h
    Deployment.where(app: org.apps).failed.where("created_at > ?", 24.hours.ago).includes(:app).each do |deployment|
      issues << { type: "deployment", severity: "critical", resource: deployment, message: "Deployment failed" }
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
end
