require "test_helper"

class SystemUpdaterTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :ran
    def initialize(result) = (@result = result)
    def execute_with_status(command)
      # The readiness pre-check probes the no-op wrapper first; treat it as available
      # here so the update wrapper under test is what gets exercised.
      return { success: true, exit_code: 0, stdout: "", stderr: "" } if command.include?("conductor-check")
      @ran = command
      @result
    end
  end

  # A server where sudo requires a password — every command (incl. the pre-check)
  # fails the way OpenSSH surfaces it.
  class NoSudoSsh
    def execute_with_status(_command)
      { success: false, exit_code: 1, stdout: "", stderr: "sudo: a password is required" }
    end
  end

  setup do
    user = User.create!(email: "su@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  def ok = { success: true, exit_code: 0, stdout: "done", stderr: "" }

  test "without passwordless sudo it fails with actionable guidance and never runs apt" do
    ssh = NoSudoSsh.new
    res = SystemUpdater.new(@server, scope: "all", ssh: ssh).apply
    refute res.success?
    assert_match(/NOPASSWD|passwordless sudo/i, res.error)
    assert_match(/sudoers/i, res.error)
  end

  test "security scope runs the security-updates wrapper (not raw apt-get)" do
    ssh = FakeSsh.new(ok)
    res = SystemUpdater.new(@server, scope: "security", ssh: ssh).apply
    assert res.success?
    assert_includes ssh.ran, ServerSudo::SECURITY_UPDATES
    refute_includes ssh.ran, "apt-get"
  end

  test "all scope runs the all-updates wrapper (apt flags live inside the wrapper)" do
    ssh = FakeSsh.new(ok)
    SystemUpdater.new(@server, scope: "all", ssh: ssh).apply
    assert_includes ssh.ran, ServerSudo::ALL_UPDATES
    refute_includes ssh.ran, "apt-get" # the deploy user can't inject apt flags
  end

  test "an unknown scope falls back to security (safe default)" do
    ssh = FakeSsh.new(ok)
    SystemUpdater.new(@server, scope: "everything", ssh: ssh).apply
    assert_includes ssh.ran, ServerSudo::SECURITY_UPDATES
  end

  test "a non-zero exit surfaces as a failure with output" do
    ssh = FakeSsh.new(success: false, exit_code: 100, stdout: "", stderr: "E: could not lock")
    res = SystemUpdater.new(@server, scope: "all", ssh: ssh).apply
    refute res.success?
    assert_includes res.output, "could not lock"
  end
end
