require "test_helper"

# The Integrations page (Settings → Integrations) lets an admin configure the
# Conductor-wide GitHub App in the browser — the UI equivalent of the
# `set_github_app` MCP tool, so the connect-github guide becomes true.
class IntegrationsTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  def admin
    @admin ||= begin
      u = User.create!(email: "admin@example.com", admin: true)
      u.ensure_personal_organization!
      u
    end
  end

  # A small but valid RSA PEM (SetGithubAppTool parses it with OpenSSL).
  def valid_pem
    @valid_pem ||= OpenSSL::PKey::RSA.new(1024).to_pem
  end

  test "an admin can view the integrations page" do
    sign_in_as(admin)

    get integrations_path

    assert_response :success
    assert_match(/GitHub App/i, @response.body)
  end

  test "a non-admin cannot access integrations" do
    user = User.create!(email: "u@example.com")
    user.ensure_personal_organization!
    sign_in_as(user)

    get integrations_path

    assert_redirected_to root_path
  end

  test "an admin can configure the GitHub App from the browser" do
    sign_in_as(admin)

    patch integrations_path, params: { app_id: "123456", private_key: valid_pem }

    assert_redirected_to integrations_path
    cred = Credential.for_provider("github_app").first
    assert_not_nil cred, "expected a github_app credential to be stored"
    assert_equal "123456", cred.api_key
    assert_equal valid_pem, cred.api_secret
    assert_nil cred.organization, "GitHub App is Conductor-wide, not org-scoped"
    assert cred.active?
  end

  test "an invalid private key is rejected and nothing is stored" do
    sign_in_as(admin)

    patch integrations_path, params: { app_id: "123456", private_key: "not-a-pem" }

    assert_response :unprocessable_entity
    assert_nil Credential.for_provider("github_app").first
  end
end
