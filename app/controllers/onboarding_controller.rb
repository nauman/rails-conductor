class OnboardingController < ApplicationController
  def show
    @organization = current_organization
  end

  def update
    if current_organization.update(name: onboarding_params[:name], onboarded_at: Time.current)
      # A self-signed-up org continues into the guided steps (plan 02 § 3, 5–7);
      # an invited org lands on the dashboard exactly as before.
      if current_organization.self_signed_up?
        redirect_to onboarding_server_path, notice: "Organization named. Next, register a server."
      else
        redirect_to root_path, notice: "You're all set — welcome to Conductor."
      end
    else
      @organization = current_organization
      render :show, status: :unprocessable_entity
    end
  end

  def agent; end

  private

  def onboarding_params
    params.require(:organization).permit(:name)
  end
end
