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
end
