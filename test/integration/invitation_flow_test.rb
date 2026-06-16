require "test_helper"

class InvitationFlowTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  test "an owner can invite someone to their org" do
    owner = User.create!(email: "owner@example.com")
    org = Organization.create_for(owner, name: "Acme")
    sign_in_as(owner)

    assert_difference -> { org.invitations.pending.count }, 1 do
      post invitations_path, params: { invitation: { email: "new@example.com", role: "member" } }
    end
  end

  test "accepting an invitation creates the account, joins the org, and signs in" do
    owner = User.create!(email: "owner@example.com")
    org = Organization.create_for(owner, name: "Acme")
    org.update!(onboarded_at: Time.current)
    inv = org.invitations.create!(email: "new@example.com", invited_by: owner)

    get accept_invitation_path(token: inv.token)

    user = User.find_by(email: "new@example.com")
    assert user, "invited user account should be created"
    assert_includes org.users, user
    assert_not inv.reload.pending?
    # Signed in: an authed page is reachable, not bounced to sign-in
    get servers_path
    assert_response :success
  end

  test "a non-owner member cannot invite" do
    owner = User.create!(email: "owner@example.com")
    org = Organization.create_for(owner, name: "Acme")
    member = User.create!(email: "member@example.com")
    org.add_member(member)
    sign_in_as(member)

    assert_no_difference -> { org.invitations.count } do
      post invitations_path, params: { invitation: { email: "x@example.com", role: "member" } }
    end
  end
end
