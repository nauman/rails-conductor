require "test_helper"

class LandingPageTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.ensure_personal_organization!
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  test "anonymous visitors see the public landing page (not a login redirect)" do
    get root_path
    assert_response :success
    assert_match(/Conductor/, @response.body)
    assert_match(/Sign in/i, @response.body)
  end

  test "signed-in users are routed from root to the dashboard" do
    sign_in_as(User.create!(email: "u@example.com"))
    get root_path
    assert_redirected_to dashboard_path
  end

  test "the dashboard still requires authentication" do
    get dashboard_path
    assert_redirected_to user_sign_in_path
  end
end
