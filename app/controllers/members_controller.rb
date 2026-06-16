class MembersController < ApplicationController
  def index
    @memberships = current_organization.memberships.includes(:user).order(:created_at)
    @invitations = current_organization.invitations.pending.order(:created_at)
    @can_manage = current_organization.owner?(current_user)
  end

  def destroy
    membership = current_organization.memberships.find(params[:id])
    if current_organization.owner?(current_user) && membership.user_id != current_user.id
      membership.destroy
      redirect_to members_path, notice: "Member removed."
    else
      redirect_to members_path, alert: "You can't remove that member."
    end
  end
end
