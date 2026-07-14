require "test_helper"

class SshKeyGenerationTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  setup do
    @user = User.create!(email: "keys@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    sign_in_as(@user)
  end

  test "generate creates a Conductor-owned keypair and stores an OpenSSH public key" do
    assert_difference -> { @org.ssh_keys.count }, 1 do
      post generate_ssh_keys_path, params: { name: "Fleet key" }
    end

    key = @org.ssh_keys.order(:created_at).last
    assert_equal "Fleet key", key.name
    assert key.private_key.present?, "private key must be stored (encrypted)"
    assert key.public_key.to_s.start_with?("ssh-ed25519 "), "public key must be an authorized_keys line, got: #{key.public_key.inspect}"
    assert_redirected_to ssh_key_path(key)
  end

  test "generate defaults the name when none is given" do
    post generate_ssh_keys_path
    assert_equal "Conductor deploy key", @org.ssh_keys.order(:created_at).last.name
  end
end
