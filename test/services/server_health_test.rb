require "test_helper"

class ServerHealthTest < ActiveSupport::TestCase
  # Minimal stand-in for SshConnection: returns canned probe output.
  class FakeSsh
    def initialize(output:, success: true, error: nil)
      @output, @success, @error = output, success, error
    end
    def execute(_cmd) = @output
    def success? = @success
    def error = @error
  end

  setup do
    user = User.create!(email: "sh@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  def health(probe, **opts)
    ServerHealth.new(@server, ssh: FakeSsh.new(output: probe, **opts)).check
  end

  CLEAN = "DISK_ROOT:42\nMEM_AVAIL_PCT:60\nLOAD1:0.30\nCORES:4\nSWAP_USED_PCT:0\nFAILED_UNITS:0\nREBOOT_REQUIRED:no\nUPTIME:100000\n"

  test "a clean server grades healthy with all checks ok" do
    r = health(CLEAN)
    assert r.ok?
    assert_equal :healthy, r.status
    assert r.checks.all? { |c| c.status == :ok }, "all checks should be ok"
  end

  test "very high disk fails and rolls up to critical" do
    r = health(CLEAN.sub("DISK_ROOT:42", "DISK_ROOT:95"))
    assert_equal :fail, r.checks.find { |c| c.key == :disk_root }.status
    assert_equal :critical, r.status
  end

  test "high (not critical) disk warns and rolls up to degraded" do
    r = health(CLEAN.sub("DISK_ROOT:42", "DISK_ROOT:85"))
    assert_equal :warn, r.checks.find { |c| c.key == :disk_root }.status
    assert_equal :degraded, r.status
  end

  test "load grades per core: warn at >=1.0/core, fail at >=2.0/core" do
    warn = health(CLEAN.sub("LOAD1:0.30", "LOAD1:4")) # 4/4 = 1.0
    assert_equal :warn, warn.checks.find { |c| c.key == :load }.status

    crit = health(CLEAN.sub("LOAD1:0.30", "LOAD1:8")) # 8/4 = 2.0
    assert_equal :fail, crit.checks.find { |c| c.key == :load }.status
  end

  test "low available memory fails" do
    r = health(CLEAN.sub("MEM_AVAIL_PCT:60", "MEM_AVAIL_PCT:3"))
    assert_equal :fail, r.checks.find { |c| c.key == :mem_avail }.status
  end

  test "failed units and reboot-required each warn -> degraded" do
    r = health(CLEAN.sub("FAILED_UNITS:0", "FAILED_UNITS:2").sub("REBOOT_REQUIRED:no", "REBOOT_REQUIRED:yes"))
    assert_equal :warn, r.checks.find { |c| c.key == :failed_units }.status
    assert_equal :warn, r.checks.find { |c| c.key == :reboot }.status
    assert_equal :degraded, r.status
  end

  test "an ssh failure returns an error result, status unknown" do
    r = health("", success: false, error: "Connection refused")
    refute r.ok?
    assert_equal :unknown, r.status
    assert_match(/refused/i, r.error)
  end

  test "no ssh configured fails fast without attempting a connection" do
    @server.update_columns(ssh_key_id: nil)
    r = ServerHealth.new(@server.reload).check
    refute r.ok?
    assert_equal :unknown, r.status
  end
end
