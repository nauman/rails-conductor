require "test_helper"

# Role integrity + the last-owner invariant. The invariant lives on Membership
# (not in a controller) so console edits, jobs, and cascading user deletion
# cannot orphan an organization.
class MembershipRolesTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @owner = User.create!(email: "owner@example.com")
    @owner_m = @org.memberships.create!(user: @owner, role: :owner)
  end

  test "editor is appended as 2 so existing rows keep their meaning" do
    assert_equal({ "member" => 0, "owner" => 1, "editor" => 2 }, Membership.roles)
    assert_equal({ "member" => 0, "owner" => 1, "editor" => 2 }, Invitation.roles)
  end

  test "an existing role=1 row is still an owner after the enum change" do
    m = @org.memberships.create!(user: User.create!(email: "a@example.com"))
    m.update_column(:role, 1)

    assert m.reload.owner?
    assert_not m.editor?
  end

  test "editors are operators but not owners" do
    editor = @org.memberships.create!(user: User.create!(email: "e@example.com"), role: :editor)

    assert editor.editor?
    assert_not editor.owner?
    assert @org.operator?(editor.user)
    assert_not @org.owner?(editor.user)
  end

  test "the last owner cannot be demoted" do
    assert_raises(ActiveRecord::RecordInvalid) { @owner_m.update!(role: :editor) }
    assert @owner_m.reload.owner?
  end

  test "the last owner cannot be destroyed" do
    assert_raises(ActiveRecord::RecordNotDestroyed) { @owner_m.destroy! }
    assert Membership.exists?(@owner_m.id)
  end

  test "an owner may be demoted while another owner remains" do
    @org.add_member(User.create!(email: "o2@example.com"), role: :owner)

    assert @owner_m.update(role: :editor)
    assert @owner_m.reload.editor?
  end

  test "a non-owner membership is freely removable" do
    m = @org.add_member(User.create!(email: "m@example.com"), role: :member)

    assert m.destroy
  end

  test "deleting the last owner's user is refused, not silently cascaded" do
    assert_raises(ActiveRecord::RecordNotDestroyed) { @owner.destroy! }
    assert User.exists?(@owner.id)
    assert @org.reload.owner?(@owner)
  end

  test "destroying the organization may still cascade its owner membership" do
    assert @org.destroy
    assert_not Membership.exists?(@owner_m.id)
  end
end
