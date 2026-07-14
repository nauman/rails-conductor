class OrganizationsController < ApplicationController
  # List the organizations the current user belongs to, with a way to create
  # more or switch between them.
  def index
    @organizations = current_user.organizations.order(:name)
  end

  def new
    @organization = Organization.new
  end

  # Self-serve org creation. The creator becomes the owner, and we switch them
  # into the new org immediately. Because the form already captures a name,
  # there's nothing left to onboard — mark it onboarded so we don't bounce the
  # user through the first-run flow again.
  def create
    @organization = Organization.create_for(current_user, name: org_params[:name])
    @organization.update!(onboarded_at: Time.current)
    session[:organization_id] = @organization.id
    redirect_to dashboard_path, notice: "“#{@organization.name}” created — you're now working in it."
  rescue ActiveRecord::RecordInvalid => e
    @organization = e.record.is_a?(Organization) ? e.record : Organization.new(name: org_params[:name])
    @organization.validate
    render :new, status: :unprocessable_entity
  end

  # Switch the active organization. Only orgs the user belongs to are selectable.
  def switch
    org = current_user.organizations.find_by(id: params[:id])
    session[:organization_id] = org.id if org
    redirect_back fallback_location: root_path
  end

  private

  def org_params
    params.require(:organization).permit(:name)
  end
end
