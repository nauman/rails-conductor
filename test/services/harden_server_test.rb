require "test_helper"

# HardenServer: the Hatchbox-style provision-&-harden orchestration. The critical
# invariant under test is NO LOCKOUT — root is only surrendered (SSH hardening +
# ssh_user flip) after a live deploy+sudo check passes. The SSH seams are faked so
# these run offline and assert ordering, gating, and idempotent re-runs.
class HardenServerTest < ActiveSupport::TestCase
  # Records every script it runs; returns success (or a scripted failure per step).
  class FakeSsh
    attr_reader :commands
    def initialize(succeed: true, fail_on: nil, output: "")
      @commands = []; @succeed = succeed; @fail_on = fail_on; @output = output
    end

    def execute_with_status(cmd)
      @commands << cmd
      ok = @succeed && !(@fail_on && cmd.include?(@fail_on))
      { success: ok, output: ok ? @output : "boom", stdout: ok ? @output : "", stderr: ok ? "" : "boom", exit_code: ok ? 0 : 1 }
    end
  end

  FakeAudit = Struct.new(:status) do
    def audit = Struct.new(:ok?, :status, :checks).new(true, status, [])
  end

  setup do
    user = User.create!(email: "harden@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   ssh_key: @key, ssh_user: "root", edge_type: "kamal_proxy")
  end

  def harden(root:, deploy:, auditor: FakeAudit.new(:secure))
    HardenServer.new(@server, root_ssh: root, deploy_ssh: deploy, auditor: auditor).call
  end

  test "happy path provisions, hardens, flips ssh_user to deploy, and returns the audit grade" do
    root = FakeSsh.new
    result = harden(root: root, deploy: FakeSsh.new(output: "DEPLOY_SUDO_OK"))

    assert result.ok?, result.error
    assert_equal :secure, result.audit_status
    assert_equal "deploy", @server.reload.ssh_user, "Conductor now manages the box as deploy"
    names = result.steps.map { |s| s[:step] }
    assert_equal %w[provision verify_deploy_sudo firewall close_db ssh_harden], names
  end

  test "SSH hardening runs only AFTER the deploy+sudo verification (no-lockout ordering)" do
    root = FakeSsh.new
    harden(root: root, deploy: FakeSsh.new(output: "DEPLOY_SUDO_OK"))

    provision_i = root.commands.index { |c| c.include?("90-deploy") }
    harden_i    = root.commands.index { |c| c.include?("PermitRootLogin no") }
    assert provision_i && harden_i, "both steps must run"
    assert provision_i < harden_i, "root-disabling SSH hardening must be the last privileged step"
  end

  test "aborts WITHOUT disabling root when deploy+sudo cannot be verified (no lockout)" do
    root = FakeSsh.new
    # deploy connection fails sudo -n → verification fails
    result = harden(root: root, deploy: FakeSsh.new(succeed: false))

    refute result.ok?
    assert_match(/verification failed/i, result.error)
    assert_equal "root", @server.reload.ssh_user, "ssh_user must NOT flip to deploy"
    refute root.commands.any? { |c| c.include?("PermitRootLogin no") }, "root login must never be disabled"
  end

  test "a failing privileged step stops the run and never disables root" do
    root = FakeSsh.new(fail_on: "ufw") # firewall step fails
    result = harden(root: root, deploy: FakeSsh.new(output: "DEPLOY_SUDO_OK"))

    refute result.ok?
    assert_match(/firewall failed/i, result.error)
    assert_equal "root", @server.reload.ssh_user
    refute root.commands.any? { |c| c.include?("PermitRootLogin no") }
  end

  test "provisioning copies Conductor's key to deploy and grants NOPASSWD sudo" do
    root = FakeSsh.new
    harden(root: root, deploy: FakeSsh.new(output: "DEPLOY_SUDO_OK"))

    provision = root.commands.first
    assert_match %r{/home/deploy/\.ssh/authorized_keys}, provision
    assert_match(/NOPASSWD:ALL/, provision)
  end

  test "whitelists Conductor's connecting IP in fail2ban so it can't self-lock" do
    root = FakeSsh.new
    harden(root: root, deploy: FakeSsh.new(output: "DEPLOY_SUDO_OK"))

    fw = root.commands.find { |c| c.include?("fail2ban") && c.include?("ignoreip") }
    assert fw, "firewall step must configure a fail2ban allowlist"
    assert_match(/SSH_CLIENT/, fw, "must whitelist the IP Conductor connects from")
    assert_match(/ignoreip = 127\.0\.0\.1/, fw)
  end

  test "includes the operator's configured trusted IPs in the fail2ban allowlist" do
    ENV["CONDUCTOR_FAIL2BAN_ALLOWLIST"] = "59.101.26.90, 203.0.113.7"
    root = FakeSsh.new
    harden(root: root, deploy: FakeSsh.new(output: "DEPLOY_SUDO_OK"))

    fw = root.commands.find { |c| c.include?("ignoreip") }
    assert_match(/59\.101\.26\.90/, fw, "operator IP must be whitelisted")
    assert_match(/203\.0\.113\.7/, fw)
  ensure
    ENV.delete("CONDUCTOR_FAIL2BAN_ALLOWLIST")
  end

  test "operator_allowlist rejects non-IP junk (no shell injection into the script)" do
    ENV["CONDUCTOR_FAIL2BAN_ALLOWLIST"] = "1.2.3.4 ; rm -rf / , 5.6.7.8"
    assert_equal "1.2.3.4 5.6.7.8", HardenServer.operator_allowlist
  ensure
    ENV.delete("CONDUCTOR_FAIL2BAN_ALLOWLIST")
  end

  test "closes an exposed host Postgres by rebinding off 0.0.0.0" do
    root = FakeSsh.new
    harden(root: root, deploy: FakeSsh.new(output: "DEPLOY_SUDO_OK"))

    close = root.commands.find { |c| c.include?("listen_addresses") }
    assert close, "must run the DB-close step"
    assert_match(/0\\?\.0\\?\.0\\?\.0:5432/, close)
    assert_match(/localhost/, close)
  end
end
