require "test_helper"

class ServerSudoTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ss@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10", ssh_user: "deploy")
  end

  test "readiness probes the no-op wrapper, not a general command" do
    probed = nil
    ssh = Object.new
    ssh.define_singleton_method(:execute_with_status) { |cmd| probed = cmd; { success: true, exit_code: 0 } }
    assert ServerSudo.ready?(ssh)
    assert_equal "sudo -n #{ServerSudo::CHECK}", probed
    refute_includes probed, "true", "must not fall back to a broad 'sudo -n true'"
  end

  test "grant installs root-owned wrappers + a NOPASSWD rule scoped to only those" do
    cmd = ServerSudo.grant_command(@server)

    # wrappers, not raw tools
    ServerSudo::WRAPPERS.each { |w| assert_includes cmd, w }
    assert_includes cmd, "chown root:root"
    assert_includes cmd, "chmod 0755"

    # sudoers grants NOPASSWD ONLY on the wrappers for this server's user
    assert_includes cmd, "deploy ALL=(root) NOPASSWD: #{ServerSudo::WRAPPERS.join(', ')}"
    assert_includes cmd, "chmod 0440 #{ServerSudo::SUDOERS_FILE}"

    # never a blanket grant, never bare apt-get in the sudoers line
    refute_includes cmd, "NOPASSWD: ALL"
    refute_match(/NOPASSWD:.*\bapt-get\b/, cmd)
  end

  test "the apt flags live inside the wrapper script, not in a sudo-able command" do
    cmd = ServerSudo.grant_command(@server)
    assert_includes cmd, "--force-confold"
    assert_includes cmd, "NEEDRESTART_MODE=l"
    assert_includes cmd, "unattended-upgrade -v"
  end

  test "remediation carries the grant + points at the docs" do
    msg = ServerSudo.remediation(@server)
    assert_match(/passwordless sudo/i, msg)
    assert_includes msg, ServerSudo::SUDOERS_FILE
    assert_includes msg, "/docs/privileged-ops"
  end
end
