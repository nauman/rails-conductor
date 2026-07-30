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

    # Authorize mutating API requests two ways: the token must be write-scoped,
    # AND its user must be an org owner/admin — the same OperatorPolicy the web
    # and MCP paths use, so a member's deploy token can't mutate infrastructure.
    def enforce_token_scope!
      return if request.get? || request.head?

      if @current_api_token&.read_only?
        return render json: { error: "This token is read-only and cannot perform writes" }, status: :forbidden
      end

      unless OperatorPolicy.operator?(current_user, current_organization)
        render json: { error: "This action requires an organization owner or editor" }, status: :forbidden
      end
    end

    # Owner-only bands (see OperatorPolicy). Controllers whose actions execute
    # code or touch stored credentials call this explicitly — the blanket
    # operator gate above admits editors, who must not reach them.
    def require_capability!(capability)
      return if OperatorPolicy.can?(current_user, current_organization, capability)

      render json: { error: "This action requires an organization owner" }, status: :forbidden
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
