class LandingController < ApplicationController
  # The landing page is the public face of Conductor — no auth required.
  skip_before_action :authenticate_user!, only: :index
  skip_before_action :set_current_organization, only: :index
  skip_before_action :require_onboarding, only: :index

  def index
    redirect_to dashboard_path if user_signed_in?
  end
end
