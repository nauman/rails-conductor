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

  # Net::SSH delivers channel data as ASCII-8BIT. Appending it to a UTF-8 buffer
  # turns the buffer binary, and the crash lands later — when that output is
  # interpolated into a UTF-8 log line:
  #
  #   Unexpected error: incompatible character encodings: UTF-8 and BINARY
  #
  # A real Starrrs deploy died exactly there. The `docker build` had SUCCEEDED;
  # only Conductor's handling of its progress output failed, so a good release
  # was reported as a failed deploy. Short command output never triggers it —
  # only verbose, non-ASCII output like a build.
  test "binary command output is made safe to interpolate into a UTF-8 log" do
    raw = "Step 1/9 : FROM ruby\n\xE2\x94\x80\xE2\x94\x80 progress \xFF\xFE bad bytes".b
    assert_equal Encoding::BINARY, raw.encoding

    clean = SshConnection.utf8(raw)

    assert_equal Encoding::UTF_8, clean.encoding
    assert clean.valid_encoding?, "must be safe to concatenate"
    assert_nothing_raised { "log: #{clean}" }
    assert_includes clean, "Step 1/9"
    assert_includes clean, "progress", "valid UTF-8 must survive, not be stripped wholesale"
  end

  test "valid UTF-8 passes through unchanged" do
    assert_equal "héllo ✓", SshConnection.utf8("héllo ✓")
  end

  test "nil output does not blow up" do
    assert_equal "", SshConnection.utf8(nil)
  end
end
