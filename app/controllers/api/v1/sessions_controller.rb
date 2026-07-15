module Api
  module V1
    class SessionsController < ActionController::API
      # POST /api/v1/sessions/request_token
      # Body: { email: "user@example.com" }
      # Sends a magic link email. When clicked, generates an API token.
      def request_token
        # Honest + non-enumerating: API token exchange isn't enabled, so this
        # sends nothing. Same response for every address (no account disclosure).
        render json: { error: "API token exchange is not available. Generate a token in the web UI (Tokens)." },
               status: :not_implemented
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
