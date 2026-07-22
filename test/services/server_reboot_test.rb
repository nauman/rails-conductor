require "test_helper"

class ServerRebootTest < ActiveSupport::TestCase
  # sudo -n true succeeds (passwordless sudo present); records issued commands.
  class ReadySsh
    attr_reader :ran
    def initialize = (@ran = [])
    def execute_with_status(cmd)
      @ran << cmd
      { success: true, exit_code: 0, stdout: "", stderr: "" }
    end
  end

  class NoSudoSsh
    def execute_with_status(_cmd) = { success: false, exit_code: 1, stdout: "", stderr: "sudo: a password is required" }
  end

  setup do
    user = User.create!(email: "rb@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  test "issues a reboot when passwordless sudo is available" do
    ssh = ReadySsh.new
    res = ServerReboot.new(@server, ssh: ssh).reboot!
    assert res.success?
    assert ssh.ran.any? { |c| c.include?("reboot") }, "expected a reboot command"
    assert_match(/reboot sent/i, res.message)
  end

  test "refuses with actionable guidance when passwordless sudo is missing" do
    res = ServerReboot.new(@server, ssh: NoSudoSsh.new).reboot!
    refute res.success?
    assert_match(/NOPASSWD|passwordless sudo/i, res.message)
  end

  test "fails cleanly when SSH is not configured" do
    @server.update_columns(ssh_key_id: nil)
    res = ServerReboot.new(@server.reload).reboot!
    refute res.success?
    assert_match(/SSH not configured/i, res.message)
  end
end
