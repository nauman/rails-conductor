require "test_helper"

class SystemUpdaterTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :ran
    def initialize(result) = (@result = result)
    def execute_with_status(command)
      @ran = command
      @result
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

  test "security scope uses unattended-upgrade (the safe, no-bounce path)" do
    ssh = FakeSsh.new(ok)
    res = SystemUpdater.new(@server, scope: "security", ssh: ssh).apply
    assert res.success?
    assert_includes ssh.ran, "unattended-upgrade"
    refute_includes ssh.ran, "apt-get -y"
  end

  test "all scope runs apt-get upgrade, keeps configs, and does not auto-restart services" do
    ssh = FakeSsh.new(ok)
    SystemUpdater.new(@server, scope: "all", ssh: ssh).apply
    assert_includes ssh.ran, "apt-get -y"
    assert_includes ssh.ran, "--force-confold"
    assert_includes ssh.ran, "NEEDRESTART_MODE=l"
  end

  test "an unknown scope falls back to security (safe default)" do
    ssh = FakeSsh.new(ok)
    SystemUpdater.new(@server, scope: "everything", ssh: ssh).apply
    assert_includes ssh.ran, "unattended-upgrade"
  end

  test "a non-zero exit surfaces as a failure with output" do
    ssh = FakeSsh.new(success: false, exit_code: 100, stdout: "", stderr: "E: could not lock")
    res = SystemUpdater.new(@server, scope: "all", ssh: ssh).apply
    refute res.success?
    assert_includes res.output, "could not lock"
  end
end
