class GuidesController < ApplicationController
  # Public docs — no auth, like the landing page.
  skip_before_action :authenticate_user!
  skip_before_action :set_current_organization
  skip_before_action :require_onboarding

  layout "guides"

  def index
    @guides = Guide.all
  end

  def show
    @guides = Guide.all
    @guide = Guide.find(params[:slug])
    return render(:not_found, status: :not_found) unless @guide
  end
end
