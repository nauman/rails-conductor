require "test_helper"

class OrganizationSwitchingTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  test "a member can switch to another of their organizations" do
    user = User.create!(email: "switcher@example.com")
    Organization.create_for(user, name: "A")
    org_b = Organization.create_for(user, name: "B")
    sign_in_as(user)

    post switch_organization_path(org_b)

    assert_equal org_b.id, session[:organization_id]
  end

  test "cannot switch into an organization you don't belong to" do
    user = User.create!(email: "switcher@example.com")
    Organization.create_for(user, name: "Mine")
    other = Organization.create!(name: "Theirs")
    sign_in_as(user)

    post switch_organization_path(other)

    assert_not_equal other.id, session[:organization_id]
  end
end
