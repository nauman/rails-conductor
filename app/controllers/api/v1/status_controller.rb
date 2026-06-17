module Api
  module V1
    class StatusController < Api::BaseController
      def show
        servers = current_organization.servers
        apps = current_organization.apps
        backups = current_organization.backups

        render json: {
          servers: {
            total: servers.count,
            online: servers.where(status: "online").count,
            degraded: servers.where(status: "degraded").count,
            offline: servers.where(status: "offline").count
          },
          apps: {
            total: apps.count,
            running: apps.where(status: "running").count,
            stopped: apps.where(status: "stopped").count,
            deploying: apps.where(status: "deploying").count,
            failed: apps.where(status: "failed").count
          },
          backups: {
            total: backups.count,
            enabled: backups.where(enabled: true).count
          },
          scripts: {
            total: Script.count
          },
          recent_deployments: Deployment.where(app_id: apps.select(:id)).order(created_at: :desc).limit(5).map { |d|
            {
              id: d.id,
              app: d.app&.name,
              status: d.status,
              created_at: d.created_at.iso8601
            }
          }
        }
      end
    end
  end
end
