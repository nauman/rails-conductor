require "test_helper"
require "securerandom"

class AuthenticationUiTest < ActionDispatch::IntegrationTest
  def test_passwordless_check_email_page_renders_retry_link
    user = User.create!(email: "operator@example.com")
    session = Passwordless::Session.create!(
      authenticatable: user,
      expires_at: 10.minutes.from_now,
      timeout_at: 10.minutes.from_now,
      token_digest: "digest",
      identifier: SecureRandom.uuid
    )

    get "/users/sign_in/#{session.identifier}"

    assert_response :success
    assert_select "a[href='#{user_sign_in_path}']", text: "try again"
  end

  def test_sign_in_page_does_not_render_theme_toggle
    get user_sign_in_path

    assert_response :success
    assert_select "#rui-theme-toggle", count: 0
    assert_select "[data-controller='theme']", count: 0
  end
end
