module Api
  module V1
    class TokensController < Api::BaseController
      # GET /api/v1/tokens - list current user's tokens
      def index
        tokens = current_user.api_tokens
        render json: tokens.map { |t|
          {
            id: t.id,
            name: t.name,
            last_used_at: t.last_used_at&.iso8601,
            created_at: t.created_at.iso8601
          }
        }
      end

      # DELETE /api/v1/tokens/:id - revoke a token
      def destroy
        token = current_user.api_tokens.find(params[:id])
        token.destroy
        render json: { message: "Token revoked" }
      end
    end
  end
end
