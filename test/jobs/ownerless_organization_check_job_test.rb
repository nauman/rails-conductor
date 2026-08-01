require "test_helper"

# SB-002 interim mitigation. Rails callbacks enforce "an org always has an
# owner", but update_column / delete_all / raw SQL bypass them. This cannot
# prevent that — it exists so the result is noticed rather than discovered when
# someone tries to manage members and finds they cannot.
class OwnerlessOrganizationCheckJobTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @owner = User.create!(email: "owner@example.com")
    @member = User.create!(email: "member@example.com")
    @org.add_member(@owner, role: :owner)
    @org.add_member(@member, role: :member)
  end

  test "a healthy organization is not reported" do
    assert_empty OwnerlessOrganizationCheckJob.ownerless
  end

  # The exact bypass SB-002 describes: update_column skips the validation.
  test "an org whose owner was demoted by a callback-skipping write is found" do
    @org.memberships.find_by(user: @owner).update_column(:role, Membership.roles[:member])

    assert_includes OwnerlessOrganizationCheckJob.ownerless, @org
  end

  test "an org whose owner membership was deleted by delete_all is found" do
    @org.memberships.owner.delete_all

    assert_includes OwnerlessOrganizationCheckJob.ownerless, @org
  end

  # Different state, currently harmless — nobody is locked out of anything,
  # because nobody is in it.
  test "an org with no memberships at all is NOT reported" do
    empty = Organization.create!(name: "Empty")

    assert_not_includes OwnerlessOrganizationCheckJob.ownerless, empty
  end

  test "it reports and does NOT repair — promoting someone is a governance decision" do
    @org.memberships.find_by(user: @owner).update_column(:role, Membership.roles[:member])

    OwnerlessOrganizationCheckJob.perform_now

    assert_empty @org.reload.memberships.owner,
                 "the job must not silently choose a new owner"
  end

  test "it returns the affected organizations so a caller can act" do
    @org.memberships.owner.delete_all

    assert_equal [ @org.id ], OwnerlessOrganizationCheckJob.perform_now.map(&:id)
  end

  test "one broken org does not hide another" do
    other = Organization.create!(name: "Other")
    other.add_member(User.create!(email: "o2@example.com"), role: :owner)
    # A remaining non-owner member is what makes it "locked out" rather than
    # merely empty — an org with nobody in it is a different, harmless state.
    other.add_member(User.create!(email: "o3@example.com"), role: :member)
    other.memberships.owner.delete_all
    @org.memberships.owner.delete_all

    assert_equal [ @org.id, other.id ].sort, OwnerlessOrganizationCheckJob.ownerless.map(&:id).sort
  end
end
