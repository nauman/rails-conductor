module Api
  class BaseController < ActionController::API
    before_action :authenticate_api_token!
    before_action :require_organization!

    rescue_from ActiveRecord::RecordNotFound do |exception|
      render json: { error: "#{exception.model || 'Record'} not found" }, status: :not_found
    end

    rescue_from ActiveRecord::RecordInvalid do |exception|
      render json: { errors: exception.record.errors.full_messages }, status: :unprocessable_entity
    end

    private

    def authenticate_api_token!
      token = request.headers["Authorization"]&.sub(/\ABearer\s+/, "")
      @current_api_token = ApiToken.authenticate(token)

      unless @current_api_token
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    def current_user
      @current_api_token&.user
    end

    def current_admin?
      current_user&.admin?
    end

    # The organization a request operates within. A token may be bound to an
    # org; if not, fall back to the user's first org so tokens created before
    # org-scoping keep working.
    def current_organization
      @current_organization ||=
        @current_api_token&.organization || @current_api_token&.user&.organizations&.first
    end

    # All API resources are org-scoped, so a token whose user has no org cannot
    # do anything meaningful. Reject the request rather than leak global data.
    def require_organization!
      return if current_organization

      render json: { error: "No organization associated with this token" }, status: :forbidden
    end
  end
end
