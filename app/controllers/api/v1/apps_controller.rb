module Api
  module V1
    class AppsController < Api::BaseController
      def index
        apps = App.includes(:server).all
        render json: apps.map { |a| app_json(a) }
      end

      def show
        app = App.find(params[:id])
        render json: app_json(app)
      end

      def deploy
        app = App.find(params[:id])
        render json: { message: "Deploy started", app: app_json(app) }
      end

      def stop
        app = App.find(params[:id])
        render json: { message: "Stop requested", app: app_json(app) }
      end

      def restart
        app = App.find(params[:id])
        render json: { message: "Restart requested", app: app_json(app) }
      end

      def logs
        app = App.find(params[:id])
        render json: { app: app.name, logs: [] }
      end

      private

      def app_json(app)
        {
          id: app.id,
          name: app.name,
          slug: app.slug,
          status: app.status,
          domain: app.domain,
          port: app.port,
          server: app.server&.name,
          server_id: app.server_id,
          repository_url: app.repository_url,
          branch: app.branch,
          notes: app.notes,
          deployed_at: app.deployed_at&.iso8601,
          container_status: app.container_status,
          ssl_enabled: app.ssl_enabled,
          created_at: app.created_at.iso8601,
          updated_at: app.updated_at.iso8601
        }
      end
    end
  end
end
