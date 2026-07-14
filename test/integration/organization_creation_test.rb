require "test_helper"

class OrganizationCreationTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  test "a signed-in user can create a new organization and is switched into it" do
    user = User.create!(email: "founder@example.com")
    user.ensure_personal_organization!
    sign_in_as(user)

    assert_difference -> { user.organizations.count }, 1 do
      post organizations_path, params: { organization: { name: "Acme" } }
    end

    org = user.organizations.order(:created_at).last
    assert_equal "Acme", org.name
    assert org.owner?(user), "creator should be the owner"
    assert org.onboarded?, "self-created org should skip onboarding"
    assert_equal org.id, session[:organization_id], "should switch into the new org"
  end

  test "creating an organization with a blank name re-renders the form" do
    user = User.create!(email: "founder@example.com")
    user.ensure_personal_organization!
    sign_in_as(user)

    assert_no_difference -> { Organization.count } do
      post organizations_path, params: { organization: { name: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "the organizations index lists the user's organizations" do
    user = User.create!(email: "founder@example.com")
    Organization.create_for(user, name: "First Org")
    Organization.create_for(user, name: "Second Org")
    sign_in_as(user)

    get organizations_path

    assert_response :success
    assert_select "body", text: /First Org/
    assert_select "body", text: /Second Org/
  end
end
