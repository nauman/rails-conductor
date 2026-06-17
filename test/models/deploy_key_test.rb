require "test_helper"

class DeployKeyTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "dk@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git")
  end

  class StubGen
    def self.generate(comment:)
      { private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n", public_key: "ssh-ed25519 AAAA #{comment}", fingerprint: "SHA256:abc" }
    end
  end

  test "generate_for stores a key pair and is regenerable (one per app)" do
    key = DeployKey.generate_for(@app, generator: StubGen)
    assert_equal @app, key.app
    assert_match "ssh-ed25519", key.public_key
    assert key.private_key.present?

    assert_no_difference -> { DeployKey.count } do
      DeployKey.generate_for(@app, generator: StubGen) # replaces
    end
    assert_equal 1, @app.reload.deploy_key ? 1 : 0
  end

  test "ssh_url converts https github urls to the ssh deploy form" do
    assert_equal "git@github.com:pavelabs/kuickr.git", DeployKey.ssh_url("https://github.com/pavelabs/kuickr.git")
    assert_equal "git@github.com:pavelabs/kuickr.git", DeployKey.ssh_url("https://github.com/pavelabs/kuickr")
    # already ssh form is left alone
    assert_equal "git@github.com:o/r.git", DeployKey.ssh_url("git@github.com:o/r.git")
  end

  test "the real generator produces a usable ed25519 keypair" do
    pair = DeployKeyGenerator.generate(comment: "conductor-test")
    assert_match "OPENSSH PRIVATE KEY", pair[:private_key]
    assert_match(/\Assh-ed25519 /, pair[:public_key])
    assert_match(/\ASHA256:/, pair[:fingerprint])
  end
end
