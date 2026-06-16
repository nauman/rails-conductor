class InvitationsController < ApplicationController
  # Accepting an invitation is how invited users first get in — no prior session.
  skip_before_action :authenticate_user!, only: :accept
  skip_before_action :require_onboarding, only: :accept

  before_action :require_owner!, only: :create

  def create
    invitation = current_organization.invitations.create!(
      email: invite_params[:email].to_s.downcase.strip,
      role: %w[member owner].include?(invite_params[:role]) ? invite_params[:role] : "member",
      invited_by: current_user
    )
    InvitationMailer.invite(invitation).deliver_later
    redirect_to members_path, notice: "Invitation sent to #{invitation.email}."
  end

  def accept
    invitation = Invitation.pending.find_by!(token: params[:token])
    user = User.find_or_create_by!(email: invitation.email)
    invitation.accept!(user)

    sign_in(Passwordless::Session.create!(authenticatable: user))
    session[:organization_id] = invitation.organization_id
    redirect_to root_path, notice: "Welcome to #{invitation.organization.name}!"
  end

  private

  def invite_params
    params.require(:invitation).permit(:email, :role)
  end

  def require_owner!
    return if current_organization.owner?(current_user)

    redirect_to members_path, alert: "Only organization owners can invite people."
  end
end
