module Api
  module V1
    class ServersController < Api::BaseController
      def index
        servers = Server.all
        render json: servers.map { |s| server_json(s) }
      end

      def show
        server = Server.find(params[:id])
        render json: server_json(server)
      end

      def create
        server = Server.new(server_params)
        if server.save
          render json: server_json(server), status: :created
        else
          render json: { errors: server.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def provision
        server = Server.find(params[:id])
        render json: { message: "Provisioning started", server: server_json(server) }
      end

      def metrics
        server = Server.find(params[:id])
        render json: server_json(server).merge(metrics: server_metrics(server))
      end

      private

      def server_params
        params.require(:server).permit(:name, :hostname, :ip_address, :provider, :region, :ssh_user, :ssh_port, :status)
      end

      def server_json(server)
        {
          id: server.id,
          name: server.name,
          hostname: server.hostname,
          ip_address: server.ip_address,
          provider: server.provider,
          ssh_user: server.ssh_user,
          ssh_port: server.ssh_port,
          status: server.status,
          cpu_percent: server.cpu_percent,
          memory_used_mb: server.memory_used_mb,
          memory_total_mb: server.memory_total_mb,
          disk_percent: server.disk_percent,
          last_seen_at: server.last_seen_at&.iso8601,
          created_at: server.created_at.iso8601,
          updated_at: server.updated_at.iso8601
        }
      end

      def server_metrics(server)
        {
          cpu_percent: server.cpu_percent,
          memory_used_mb: server.memory_used_mb,
          memory_total_mb: server.memory_total_mb,
          disk_percent: server.disk_percent,
          metrics_fresh: server.metrics_fresh?,
          formatted_memory: server.formatted_memory
        }
      end
    end
  end
end
