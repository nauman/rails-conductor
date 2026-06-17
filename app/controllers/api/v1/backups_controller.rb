module Api
  module V1
    class BackupsController < Api::BaseController
      def index
        backups = current_organization.backups
        render json: backups.map { |b| backup_json(b) }
      end

      def show
        backup = current_organization.backups.find(params[:id])
        render json: backup_json(backup)
      end

      def run
        backup = current_organization.backups.find(params[:id])
        render json: { message: "Backup triggered", backup: backup_json(backup) }
      end

      private

      def backup_json(backup)
        {
          id: backup.id,
          provider: backup.provider,
          bucket_name: backup.bucket_name,
          schedule: backup.schedule,
          enabled: backup.enabled,
          status: backup.status,
          last_run_at: backup.last_run_at&.iso8601,
          next_run_at: backup.next_run_at&.iso8601,
          retention_days: backup.retention_days,
          size_bytes: backup.size_bytes,
          server: backup.server&.name,
          app: backup.app&.name,
          created_at: backup.created_at.iso8601
        }
      end
    end
  end
end
