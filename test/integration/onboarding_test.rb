require "test_helper"

class OnboardingTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  test "an un-onboarded user is redirected to onboarding" do
    user = User.create!(email: "new@example.com")
    Organization.create_for(user, name: "new") # onboarded_at is nil
    sign_in_as(user)

    get servers_path
    assert_redirected_to onboarding_path
  end

  test "completing onboarding names the org and stops redirecting" do
    user = User.create!(email: "new@example.com")
    org = Organization.create_for(user, name: "new")
    sign_in_as(user)

    patch onboarding_path, params: { organization: { name: "Acme Inc" } }

    assert_redirected_to root_path
    assert_equal "Acme Inc", org.reload.name
    assert org.onboarded?

    get servers_path
    assert_response :success
  end

  test "onboarding page itself is reachable without a redirect loop" do
    user = User.create!(email: "new@example.com")
    Organization.create_for(user, name: "new")
    sign_in_as(user)

    get onboarding_path
    assert_response :success
  end
end
