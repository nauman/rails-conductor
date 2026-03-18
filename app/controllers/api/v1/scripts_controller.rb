module Api
  module V1
    class ScriptsController < Api::BaseController
      def index
        scripts = Script.all
        render json: scripts.map { |s| script_json(s) }
      end

      def show
        script = Script.find(params[:id])
        render json: script_json(script)
      end

      def run
        script = Script.find(params[:script_id])
        server = Server.find(params[:server_id])
        script_run = ScriptRun.create!(
          script: script,
          server: server,
          user: current_user,
          status: "pending"
        )
        ScriptRunJob.perform_later(script_run.id)
        render json: {
          message: "Script execution started",
          script_run: {
            id: script_run.id,
            script: script.name,
            server: server.name,
            status: script_run.status
          }
        }, status: :created
      end

      private

      def script_json(script)
        {
          id: script.id,
          name: script.name,
          description: script.description,
          script_type: script.script_type,
          built_in: script.built_in,
          created_at: script.created_at.iso8601
        }
      end
    end
  end
end
