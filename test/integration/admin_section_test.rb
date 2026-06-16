require "test_helper"

class AdminSectionTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  test "a webmaster sees all organizations across the instance" do
    admin = User.create!(email: "admin@example.com", admin: true)
    admin.ensure_personal_organization!
    Organization.create_for(User.create!(email: "x@example.com"), name: "OtherOrg")
    sign_in_as(admin)

    get admin_organizations_path

    assert_response :success
    assert_match "OtherOrg", @response.body
  end

  test "a webmaster sees all users across the instance" do
    admin = User.create!(email: "admin@example.com", admin: true)
    admin.ensure_personal_organization!
    User.create!(email: "someone-else@example.com")
    sign_in_as(admin)

    get admin_users_path

    assert_response :success
    assert_match "someone-else@example.com", @response.body
  end

  test "a non-admin cannot access the admin section" do
    user = User.create!(email: "u@example.com")
    user.ensure_personal_organization!
    sign_in_as(user)

    get admin_organizations_path

    assert_redirected_to root_path
  end
end
