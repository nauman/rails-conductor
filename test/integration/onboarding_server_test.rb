require "test_helper"

# Plan 02 § 9 step 8: onboarding steps 2–4 for a signed-up org. The repo has no
# Capybara system-test setup, so these drive the same pages as request tests.
class OnboardingServerTest < ActionDispatch::IntegrationTest
  setup do
    @owner, @org = signed_up_tenant(onboarded: false)
    ps = Passwordless::Session.create!(authenticatable: @owner)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  test "naming the org leads a signed-up tenant into server registration" do
    patch onboarding_path, params: { organization: { name: "Acme" } }
    assert_redirected_to onboarding_server_path
  end

  test "happy path: register, install the line, verify, then connect an agent" do
    @org.update!(onboarded_at: Time.current)
    post onboarding_server_path, params: { server: { name: "web-1", ip_address: "8.8.8.8", ssh_user: "deploy", ssh_port: 22 } }
    server = @org.servers.find_by!(name: "web-1")
    assert_redirected_to onboarding_server_verification_path(server)
    refute server.ownership_verified?

    follow_redirect!
    line = css_select("#authorized-keys-line").text.strip
    assert_match(/\Assh-ed25519 \S+ conductor-verify-#{server.reload.ownership_nonce}\z/, line)

    fake = FakeOwnershipSsh.new("conductor-verify-#{server.ownership_nonce}\n")
    SshConnection.stub(:new, fake) do
      post verify_onboarding_server_path(server)
    end
    assert_redirected_to onboarding_agent_path
    assert server.reload.ownership_verified?

    follow_redirect!
    assert_match "/mcp", response.body
  end

  test "failed proof of control keeps the server unverified and says why" do
    @org.update!(onboarded_at: Time.current)
    post onboarding_server_path, params: { server: { name: "web-1", ip_address: "8.8.8.8" } }
    server = @org.servers.find_by!(name: "web-1")

    fake = FakeOwnershipSsh.new("", error: "Authentication failed: deploy")
    SshConnection.stub(:new, fake) do
      post verify_onboarding_server_path(server)
    end
    assert_response :unprocessable_entity
    assert_match "Not verified yet: Authentication failed", response.body
    refute server.reload.ownership_verified?
  end

  test "a private address is refused at registration" do
    @org.update!(onboarded_at: Time.current)
    post onboarding_server_path, params: { server: { name: "lan", ip_address: "169.254.169.254" } }
    assert_response :unprocessable_entity
    assert_nil @org.servers.find_by(name: "lan")
    assert_equal 0, @org.ssh_keys.count, "the generated key does not outlive a refused registration"
  end

  test "another org's server cannot be verified through this org" do
    @org.update!(onboarded_at: Time.current)
    _u, other = signed_up_tenant(email: "other@example.com")
    theirs = other.servers.create!(name: "theirs", ip_address: "8.8.4.4", status: "offline")
    post verify_onboarding_server_path(theirs)
    assert_response :not_found
  end
end
