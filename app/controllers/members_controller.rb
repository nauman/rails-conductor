class MembersController < ApplicationController
  before_action :require_manage_members!, only: [ :update, :destroy ]
  before_action :set_membership, only: [ :update, :destroy ]

  def index
    @memberships = current_organization.memberships.includes(:user).order(:created_at)
    @invitations = current_organization.invitations.pending.order(:created_at)
    @can_manage = OperatorPolicy.can?(current_user, current_organization, :manage_members)
  end

  # Promote/demote. The last-owner invariant is enforced on Membership itself, so
  # a concurrent double-demotion or a console edit can't orphan the org either.
  def update
    role = params[:role].to_s
    unless Membership.roles.key?(role)
      return redirect_to members_path, alert: "Unknown role."
    end

    if @membership.update(role: role)
      redirect_to members_path, notice: "#{@membership.user.email} is now #{role == 'owner' ? 'an' : 'a'} #{role}."
    else
      redirect_to members_path, alert: @membership.errors.full_messages.to_sentence
    end
  end

  def destroy
    if @membership.user_id == current_user.id
      return redirect_to members_path, alert: "You can't remove yourself."
    end

    if @membership.destroy
      redirect_to members_path, notice: "Member removed."
    else
      redirect_to members_path, alert: @membership.errors.full_messages.to_sentence
    end
  end

  private

  def set_membership
    @membership = current_organization.memberships.find(params[:id])
  end

  def require_manage_members!
    return if OperatorPolicy.can?(current_user, current_organization, :manage_members)

    redirect_to members_path, alert: "Managing members requires an organization owner."
  end
end
