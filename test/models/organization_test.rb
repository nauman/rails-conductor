require "test_helper"

class OrganizationTest < ActiveSupport::TestCase
  test "requires a name" do
    assert_not Organization.new.valid?
  end

  test "create_for builds an org owned by the user" do
    user = User.create!(email: "owner@example.com")
    org = Organization.create_for(user, name: "Acme")

    assert_equal "Acme", org.name
    assert_includes org.users, user
    assert org.owner?(user)
  end

  test "a user can belong to multiple organizations" do
    user = User.create!(email: "multi@example.com")
    Organization.create_for(user, name: "A")
    Organization.create_for(user, name: "B")

    assert_equal 2, user.organizations.count
  end

  test "add_member adds a plain member (not an owner)" do
    owner = User.create!(email: "o@example.com")
    org = Organization.create_for(owner, name: "Acme")
    member = User.create!(email: "m@example.com")

    org.add_member(member)

    assert_includes org.users, member
    assert_not org.owner?(member)
  end
end
