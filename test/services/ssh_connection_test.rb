require "test_helper"

class SshConnectionTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ssh@example.com")
    org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: org)
    @server = org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                  ssh_key: key, ssh_user: "deploy")
  end

  test "host-key verification is enabled (TOFU accept_new), not disabled" do
    opts = SshConnection.new(@server).send(:ssh_options)
    assert_equal :accept_new, opts[:verify_host_key], "must not be :never — that trusts any host key (MITM)"
    assert opts[:user_known_hosts_file].present?, "a managed known_hosts file records/verifies keys"
  end

  test "CONDUCTOR_KNOWN_HOSTS overrides the known_hosts path" do
    original = ENV["CONDUCTOR_KNOWN_HOSTS"]
    ENV["CONDUCTOR_KNOWN_HOSTS"] = File.join(Dir.mktmpdir, "kh")
    assert_equal ENV["CONDUCTOR_KNOWN_HOSTS"], SshConnection.new(@server).send(:ssh_options)[:user_known_hosts_file]
  ensure
    ENV["CONDUCTOR_KNOWN_HOSTS"] = original
  end
end
