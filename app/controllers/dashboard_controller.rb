class DashboardController < ApplicationController
  def index
    @servers = Server.order(:name)
    @apps = App.includes(:server).order(:name)
    @backups = Backup.includes(:server, :app).recent.limit(10)
    @credentials = Credential.order(:name)

    # Recent deployments (last 10)
    @recent_deployments = Deployment.includes(:app, :user).recent.limit(10)

    # Issues - what needs attention
    @issues = collect_issues

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
      backups_completed: Backup.completed.count,
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

  def collect_issues
    issues = []

    # Offline servers
    Server.offline.each do |server|
      issues << { type: "server", severity: "critical", resource: server, message: "Server is offline" }
    end

    # Degraded servers
    Server.degraded.each do |server|
      issues << { type: "server", severity: "warning", resource: server, message: "Server is degraded" }
    end

    Server.order(:name).each do |server|
      next unless server.metrics_stale?
      next if server.status == "offline"

      issues << { type: "server", severity: "warning", resource: server, message: "Server metrics are stale" }
    end

    # High CPU servers (>80%)
    Server.where("cpu_percent > 80").where("metrics_updated_at > ?", 5.minutes.ago).each do |server|
      issues << { type: "server", severity: "warning", resource: server, message: "High CPU usage (#{server.cpu_percent}%)" }
    end

    # High disk servers (>85%)
    Server.where("disk_percent > 85").where("metrics_updated_at > ?", 5.minutes.ago).each do |server|
      issues << { type: "server", severity: "warning", resource: server, message: "High disk usage (#{server.disk_percent}%)" }
    end

    App.includes(:server).order(:name).each do |app|
      next unless app.status_stale?

      issues << { type: "app", severity: "warning", resource: app, message: "Container status is stale" }
    end

    # Failed apps
    App.failed.includes(:server).each do |app|
      issues << { type: "app", severity: "critical", resource: app, message: "App deployment failed" }
    end

    # Stopped apps (might be intentional, but worth noting)
    App.stopped.includes(:server).each do |app|
      issues << { type: "app", severity: "info", resource: app, message: "App is stopped" }
    end

    # Failed deployments in last 24h
    Deployment.failed.where("created_at > ?", 24.hours.ago).includes(:app).each do |deployment|
      issues << { type: "deployment", severity: "critical", resource: deployment, message: "Deployment failed" }
    end

    # Failed backups
    Backup.where(status: "failed").where("created_at > ?", 7.days.ago).each do |backup|
      issues << { type: "backup", severity: "warning", resource: backup, message: "Backup failed" }
    end

    Backup.enabled.find_each do |backup|
      next unless backup.dispatch_overdue?

      issues << { type: "backup", severity: "warning", resource: backup, message: "Scheduled backup dispatch is overdue" }
    end

    # Sort by severity (critical first)
    severity_order = { "critical" => 0, "warning" => 1, "info" => 2 }
    issues.sort_by { |i| severity_order[i[:severity]] }
  end
end
