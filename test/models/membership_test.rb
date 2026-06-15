require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  test "role defaults to member" do
    m = Membership.create!(user: User.create!(email: "u@example.com"),
                           organization: Organization.create!(name: "Acme"))
    assert m.member?
    assert_not m.owner?
  end

  test "a user can join an organization only once" do
    user = User.create!(email: "u@example.com")
    org = Organization.create!(name: "Acme")
    Membership.create!(user: user, organization: org)

    assert_not Membership.new(user: user, organization: org).valid?
  end
end
