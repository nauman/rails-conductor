module Api
  class BaseController < ActionController::API
    before_action :authenticate_api_token!

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
  end
end
