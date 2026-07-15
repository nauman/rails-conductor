require "test_helper"

class ServerAuditTest < ActiveSupport::TestCase
  class FakeSsh
    def initialize(output:, success: true, error: nil)
      @output, @success, @error = output, success, error
    end
    def execute(_cmd) = @output
    def success? = @success
    def error = @error
  end

  setup do
    user = User.create!(email: "sa@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  SECURE = "UFW:active\nFAIL2BAN:active\nSSH_ROOT:no\nSSH_PASSWORD:no\nSEC_UPDATES:0\nUPDATES:5\nREBOOT:no\nAUTOUPGRADE:active\nDB_PUBLIC:\n"

  def audit(probe, **o) = ServerAudit.new(@server, ssh: FakeSsh.new(output: probe, **o)).audit

  test "a hardened server grades secure" do
    r = audit(SECURE)
    assert r.ok?
    assert_equal :secure, r.status
    assert r.checks.none? { |c| [ :warn, :fail ].include?(c.status) }
  end

  test "SSH root login enabled is a fail -> at_risk" do
    r = audit(SECURE.sub("SSH_ROOT:no", "SSH_ROOT:yes"))
    assert_equal :fail, r.checks.find { |c| c.key == :ssh_root }.status
    assert_equal :at_risk, r.status
  end

  test "a publicly-exposed database is a fail" do
    r = audit(SECURE.sub("DB_PUBLIC:", "DB_PUBLIC:0.0.0.0:5432"))
    db = r.checks.find { |c| c.key == :db_exposure }
    assert_equal :fail, db.status
    assert_match(/5432/, db.detail)
    assert_equal :at_risk, r.status
  end

  test "pending security updates are a fail" do
    r = audit(SECURE.sub("SEC_UPDATES:0", "SEC_UPDATES:3"))
    assert_equal :fail, r.checks.find { |c| c.key == :security_updates }.status
  end

  test "fail2ban off + reboot required warn -> attention" do
    r = audit(SECURE.sub("FAIL2BAN:active", "FAIL2BAN:inactive").sub("REBOOT:no", "REBOOT:yes"))
    assert_equal :warn, r.checks.find { |c| c.key == :fail2ban }.status
    assert_equal :warn, r.checks.find { |c| c.key == :reboot }.status
    assert_equal :attention, r.status
  end

  test "ssh failure returns an unknown result" do
    r = audit("", success: false, error: "Connection refused")
    refute r.ok?
    assert_equal :unknown, r.status
  end
end
