class OnboardingController < ApplicationController
  def show
    @organization = current_organization
  end

  def update
    if current_organization.update(name: onboarding_params[:name], onboarded_at: Time.current)
      redirect_to root_path, notice: "You're all set — welcome to Conductor."
    else
      @organization = current_organization
      render :show, status: :unprocessable_entity
    end
  end

  private

  def onboarding_params
    params.require(:organization).permit(:name)
  end
end
