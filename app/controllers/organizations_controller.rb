class OrganizationsController < ApplicationController
  # Switch the active organization. Only orgs the user belongs to are selectable.
  def switch
    org = current_user.organizations.find_by(id: params[:id])
    session[:organization_id] = org.id if org
    redirect_back fallback_location: root_path
  end
end
