require "test_helper"

# The three-role capability model (SC-009). `operator?` answers "may run ordinary
# infra ops" (owner OR editor); `can?` answers the owner-only bands.
class OperatorPolicyTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @owner = User.create!(email: "owner@example.com")
    @editor = User.create!(email: "editor@example.com")
    @member = User.create!(email: "member@example.com")
    @admin = User.create!(email: "admin@example.com", admin: true)
    @outsider = User.create!(email: "outsider@example.com")

    @org.add_member(@owner, role: :owner)
    @org.add_member(@editor, role: :editor)
    @org.add_member(@member, role: :member)
  end

  test "operator? admits owners, editors, and platform admins" do
    assert OperatorPolicy.operator?(@owner, @org)
    assert OperatorPolicy.operator?(@editor, @org)
    assert OperatorPolicy.operator?(@admin, @org)
  end

  test "operator? rejects plain members, outsiders, and nil" do
    assert_not OperatorPolicy.operator?(@member, @org)
    assert_not OperatorPolicy.operator?(@outsider, @org)
    assert_not OperatorPolicy.operator?(nil, @org)
    assert_not OperatorPolicy.operator?(@owner, nil)
  end

  test "owner-only capabilities are denied to editors and members" do
    OperatorPolicy::OWNER_ONLY.each do |capability|
      assert OperatorPolicy.can?(@owner, @org, capability),
             "owner should hold #{capability}"
      assert OperatorPolicy.can?(@admin, @org, capability),
             "platform admin should hold #{capability}"
      assert_not OperatorPolicy.can?(@editor, @org, capability),
                 "editor must NOT hold #{capability}"
      assert_not OperatorPolicy.can?(@member, @org, capability),
                 "member must NOT hold #{capability}"
    end
  end

  test "an unrecognized capability falls back to the operator gate" do
    assert OperatorPolicy.can?(@editor, @org, :deploy)
    assert_not OperatorPolicy.can?(@member, @org, :deploy)
  end

  test "capabilities are org-scoped — membership elsewhere grants nothing" do
    other = Organization.create!(name: "Other")
    other.add_member(@outsider, role: :owner)

    assert_not OperatorPolicy.operator?(@outsider, @org)
    assert_not OperatorPolicy.can?(@outsider, @org, :destroy)
  end
end
