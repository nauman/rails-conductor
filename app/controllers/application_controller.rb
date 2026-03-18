class ApplicationController < ActionController::Base
  include Passwordless::ControllerHelpers

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Require authentication for all controllers except sign in
  before_action :authenticate_user!

  helper_method :current_user, :user_signed_in?, :current_admin?

  rescue_from ActiveRecord::RecordNotFound do |_exception|
    respond_to do |format|
      format.html { render file: Rails.public_path.join("404.html"), status: :not_found, layout: false }
      format.json { render json: { error: "Not found" }, status: :not_found }
    end
  end

  rescue_from ActionController::RoutingError do |_exception|
    respond_to do |format|
      format.html { render file: Rails.public_path.join("404.html"), status: :not_found, layout: false }
      format.json { render json: { error: "Not found" }, status: :not_found }
    end
  end

  def current_user
    @current_user ||= authenticate_by_session(User)
  end

  def user_signed_in?
    current_user.present?
  end

  def current_admin?
    current_user&.admin?
  end

  def authenticate_user!
    return if request.path.start_with?("/users/sign")
    return if user_signed_in?

    session[:return_to] = request.fullpath if request.get?
    redirect_to user_sign_in_path, alert: "Please sign in to continue."
  end

  def require_admin!
    return if current_admin?

    redirect_to root_path, alert: "Admin access required."
  end
end
