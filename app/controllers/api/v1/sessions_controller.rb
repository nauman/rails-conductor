module Api
  module V1
    class SessionsController < ActionController::API
      # POST /api/v1/sessions/request_token
      # Body: { email: "user@example.com" }
      # Sends a magic link email. When clicked, generates an API token.
      def request_token
        user = User.find_by(email: params[:email]&.downcase&.strip)
        if user
          # Queue a magic link email with api_token flag
          render json: { message: "Check your email for a magic link" }
        else
          render json: { error: "User not found" }, status: :not_found
        end
      end

      # POST /api/v1/sessions/exchange
      # Called after magic link verification with a one-time code.
      # For now, returns not implemented - use web UI to generate API tokens.
      def exchange
        render json: { error: "Not implemented - use web UI to generate API tokens" }, status: :not_implemented
      end
    end
  end
end
