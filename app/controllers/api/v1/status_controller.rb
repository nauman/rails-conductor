module Api
  module V1
    class StatusController < Api::BaseController
      def show
        render json: {
          servers: {
            total: Server.count,
            online: Server.where(status: "online").count,
            degraded: Server.where(status: "degraded").count,
            offline: Server.where(status: "offline").count
          },
          apps: {
            total: App.count,
            running: App.where(status: "running").count,
            stopped: App.where(status: "stopped").count,
            deploying: App.where(status: "deploying").count,
            failed: App.where(status: "failed").count
          },
          backups: {
            total: Backup.count,
            enabled: Backup.where(enabled: true).count
          },
          scripts: {
            total: Script.count
          },
          recent_deployments: Deployment.order(created_at: :desc).limit(5).map { |d|
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
