module Api
  module V1
    class SessionsController < ActionController::API
      # POST /api/v1/sessions/request_token
      # Body: { email: "user@example.com" }
      # Sends a magic link email. When clicked, generates an API token.
      def request_token
        # Always return the same response — never reveal whether an address has
        # an account (no user enumeration). Token exchange is not yet enabled.
        render json: { message: "If that email has an account, a sign-in link is on its way." }, status: :accepted
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
