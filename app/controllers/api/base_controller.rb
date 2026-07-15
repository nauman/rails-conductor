module Api
  class BaseController < ActionController::API
    before_action :authenticate_api_token!
    before_action :require_organization!
    before_action :enforce_token_scope!

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

      # Revoke on membership removal: a valid token whose user has left the
      # token's org grants nothing (matches the MCP endpoint's rule).
      org = @current_api_token&.organization
      valid = @current_api_token && (org.nil? || @current_api_token.user.organizations.exists?(id: org.id))

      render json: { error: "Unauthorized" }, status: :unauthorized unless valid
    end

    # Read-only tokens (scope "read") may only make safe requests. Any mutating
    # verb (POST/PATCH/PUT/DELETE) requires a write-scoped token.
    def enforce_token_scope!
      return if request.get? || request.head?
      return unless @current_api_token&.read_only?

      render json: { error: "This token is read-only and cannot perform writes" }, status: :forbidden
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
