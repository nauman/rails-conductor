module Api
  module V1
    class TokensController < Api::BaseController
      # GET /api/v1/tokens - list the caller's tokens in the active org only.
      def index
        tokens = current_user.api_tokens.where(organization: current_organization)
        render json: tokens.map { |t|
          {
            id: t.id,
            name: t.name,
            last_used_at: t.last_used_at&.iso8601,
            created_at: t.created_at.iso8601
          }
        }
      end

      # DELETE /api/v1/tokens/:id - revoke a token in the active org.
      def destroy
        token = current_user.api_tokens.where(organization: current_organization).find(params[:id])
        token.destroy
        render json: { message: "Token revoked" }
      end
    end
  end
end
