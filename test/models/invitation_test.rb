require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "owner@example.com")
    @org = Organization.create_for(@owner, name: "Acme")
  end

  test "generates a token and starts pending" do
    inv = @org.invitations.create!(email: "x@example.com", invited_by: @owner)
    assert inv.token.present?
    assert inv.pending?
  end

  test "accept! creates a membership with the invited role and marks accepted" do
    inv = @org.invitations.create!(email: "x@example.com", role: :owner, invited_by: @owner)
    user = User.create!(email: "x@example.com")

    inv.accept!(user)

    assert_includes @org.users, user
    assert @org.owner?(user)
    assert_not inv.reload.pending?
  end

  test "accept! is a no-op if the user is already a member" do
    member = User.create!(email: "m@example.com")
    @org.add_member(member)
    inv = @org.invitations.create!(email: "m@example.com", invited_by: @owner)

    assert_nothing_raised { inv.accept!(member) }
    assert_equal 1, @org.memberships.where(user: member).count
  end
end
