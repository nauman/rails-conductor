require "test_helper"

# Conductor generates a keypair and — per its own tool description — hands the
# operator the public half "to add to your servers' authorized_keys". So the
# automated identity was never installed by the automation; it was a manual errand
# documented as a feature, and cross-box deploys failed until someone did it by hand.
#
# Registration is the moment to fix this: it is the one time Conductor legitimately
# holds root. Everything after is repair.
class ServerIdentityTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "si@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = @org.ssh_keys.create!(name: "Conductor deploy key", private_key: TEST_PRIVATE_KEY)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.55",
                                   ssh_user: "deploy", ssh_key: @key)
  end

  # A key Conductor cannot present is not an identity.
  test "installing needs a key with a public half" do
    @server.update!(ssh_key: nil)

    result = ServerIdentity.new(@server, ssh: FakeSsh.new, verifier: FakeSsh.new).ensure!

    assert_not result.ok?
    assert_match(/no ssh key/i, result.reason)
  end

  test "the key is appended for the deploy user, idempotently" do
    ssh = FakeSsh.new(authorized: "")
    ServerIdentity.new(@server, ssh: ssh, verifier: ssh).ensure!

    assert ssh.commands.any? { |c| c.include?("authorized_keys") }
    assert ssh.commands.any? { |c| c.include?("grep") }, "must check before appending, or it duplicates"
  end

  # VERIFY BY CONNECTING, not by trusting the write. A recorded authorization nobody
  # tested is the stale-fact pattern this fleet keeps paying for.
  test "success requires a fresh connection made with that key" do
    ssh = FakeSsh.new(authorized: "")
    result = ServerIdentity.new(@server, ssh: ssh, verifier: ssh).ensure!

    assert result.ok?
    assert ssh.verified?, "the identity is only established once it has been used"
    assert ssh.verified_under_restriction?,
           "verification must offer ONLY the stored key, or it can pass on the operator's"
  end

  test "a write that appears to succeed but does not authenticate is a failure" do
    ssh = FakeSsh.new(authorized: "", verify_succeeds: false)

    result = ServerIdentity.new(@server, ssh: ssh, verifier: ssh).ensure!

    assert_not result.ok?
    assert_match(/could not authenticate/i, result.reason)
  end

  # Already present: nothing is written, and it still verifies.
  # The PEM in `public_key` is not what sshd reads. Installing it would authorize
  # nothing and report nothing — a file that looks written and does not work.
  test "the installed key is an openssh authorized_keys line, not PEM" do
    line = @key.authorized_keys_line

    assert_match(/\Assh-rsa [A-Za-z0-9+\/=]+ /, line)
    assert_no_match(/BEGIN PUBLIC KEY/, line)
  end

  test "an already-authorized key is left alone" do
    ssh = FakeSsh.new(authorized: @key.authorized_keys_line)

    result = ServerIdentity.new(@server, ssh: ssh, verifier: ssh).ensure!

    assert result.ok?
    assert_equal "already-authorized", result.action
    assert ssh.commands.any? { |c| c.include?("CONDUCTOR_KEY_PRESENT") || c.include?("grep -qF") },
           "must check before appending"
  end

  # Writing into authorized_keys grants durable access to a machine. However routine
  # it looks, that is a credentials operation and must not be editor-safe.
  test "repairing an identity needs the credentials capability" do
    assert_equal :credentials, ToolAuthorization.capability_for("conductor_server", "repair_identity")
    assert_not ToolAuthorization.read_only?("conductor_server", "repair_identity")
  end

  class FakeSsh
    attr_reader :commands
    def initialize(authorized: "", verify_succeeds: true)
      @authorized = authorized
      @verify_succeeds = verify_succeeds
      @commands = []
      @verified = false
    end

    def verified? = @verified

    # Verification MUST go through with_only_stored_key, or it could pass on a
    # credential that is not the one being installed.
    def with_only_stored_key
      @restricted = true
      yield self
    ensure
      @restricted = false
    end

    def restricted? = @restricted

    def execute_with_status(command)
      @commands << command
      if command.include?("CONDUCTOR_IDENTITY_OK")
        @verified = true
        @verified_under_restriction = @restricted
        return { success: @verify_succeeds, stdout: @verify_succeeds ? "CONDUCTOR_IDENTITY_OK\n" : "", stderr: "" }
      end
      if command.include?("authorized_keys")
        blob = @authorized.to_s.split[1].to_s
        present = blob.present? && command.include?(blob)
        return { success: true, stdout: present ? "CONDUCTOR_KEY_PRESENT\n" : "CONDUCTOR_KEY_ADDED\n", stderr: "" }
      end
      { success: true, stdout: "", stderr: "" }
    end

    def verified_under_restriction? = @verified_under_restriction

    def error = nil
  end

  TEST_PRIVATE_KEY = OpenSSL::PKey::RSA.new(2048).to_pem.freeze
end
