require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "the first ever user bootstraps as the admin (webmaster)" do
    assert_equal 0, User.count, "expected no users before bootstrap"
    user = User.fetch_resource_for_passwordless("boss@example.com")
    assert user.admin?, "first user should be admin"
  end

  test "existing users can request a magic link (found, case-insensitive)" do
    user = User.create!(email: "member@example.com")
    assert_equal user, User.fetch_resource_for_passwordless("MEMBER@example.com")
  end

  test "unknown emails get no account once a user exists (invite-only)" do
    User.create!(email: "owner@example.com") # past the first-user bootstrap
    assert_no_difference -> { User.count } do
      assert_nil User.fetch_resource_for_passwordless("stranger@example.com")
    end
  end

  test "ensure_personal_organization! creates one org owned by the user" do
    user = User.create!(email: "solo@example.com")
    assert_difference -> { Organization.count }, 1 do
      user.ensure_personal_organization!
    end
    assert user.organizations.first.owner?(user)
  end

  test "ensure_personal_organization! is idempotent" do
    user = User.create!(email: "solo@example.com")
    user.ensure_personal_organization!
    assert_no_difference -> { Organization.count } do
      user.ensure_personal_organization!
    end
  end

  test "the bootstrapped first user gets a personal organization" do
    user = User.fetch_resource_for_passwordless("boss@example.com")
    assert user.organizations.any?
    assert user.organizations.first.owner?(user)
  end
end
