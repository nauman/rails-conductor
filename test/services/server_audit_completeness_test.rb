require "test_helper"

# The grade this produces BLOCKS deploys (DeployPreflight#audit_check). Every
# privileged probe in PROBE uses `sudo -n` and degrades to blank on failure, and
# blank was graded as the insecure answer — so a box where sudo is not granted, or
# where the probe was truncated, graded `at_risk` and read identically to a box
# with its firewall genuinely off.
#
# Run by hand that is a confusing result. Run on a schedule it silently blocks
# deploys that previously succeeded, which is why the sweep was disabled.
#
# "Could not look" is not "found a problem".
class ServerAuditCompletenessTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "sac@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.30")
  end

  def grade(lines) = ServerAudit.new(@server, ssh: nil).grade_output(lines.join("\n"))

  SECURE = [
    "SUDO:yes", "UFW:active", "FAIL2BAN:active", "SSH_ROOT:no", "SSH_PASSWORD:no",
    "SEC_UPDATES:0", "UPDATES:0", "REBOOT:no", "AUTOUPGRADE:active", "DB_PUBLIC:",
    "PROBE_END:ok"
  ].freeze

  test "a complete secure probe still grades secure" do
    assert_equal :secure, grade(SECURE).status
  end

  test "a complete probe with real exposure still grades at_risk" do
    result = grade(SECURE.map { |l| l.start_with?("UFW:") ? "UFW:inactive" : l })

    assert_equal :at_risk, result.status, "a firewall genuinely off must still block"
  end

  # THE BUG. Without sudo, every privileged value is blank — and blank read as
  # "firewall off, root login on, database public".
  test "no passwordless sudo is inconclusive, never at_risk" do
    result = grade([ "SUDO:no", "FAIL2BAN:active", "UFW:", "SSH_ROOT:", "SSH_PASSWORD:",
                     "SEC_UPDATES:0", "UPDATES:0", "REBOOT:no", "AUTOUPGRADE:active",
                     "DB_PUBLIC:", "PROBE_END:ok" ])

    assert_nil result.status, "an unreadable box has no grade"
    assert result.error.present?, "and must say why"
    assert_match(/sudo/i, result.error)
  end

  # Truncated output — a dropped connection mid-probe — must not be graded either.
  test "a truncated probe is inconclusive" do
    result = grade([ "SUDO:yes", "UFW:active", "FAIL2BAN:active" ])

    assert_nil result.status
    assert_match(/incomplete/i, result.error)
  end

  # The job already refuses to write a statusless result, so inconclusive degrades
  # to "stale" rather than to a fresh false grade. This pins the two together.
  test "an inconclusive audit leaves the recorded grade and its timestamp alone" do
    @server.update_columns(last_audit_status: "secure", last_audit_at: 40.days.ago)
    auditor = Object.new
    auditor.define_singleton_method(:audit) { ServerAudit::Result.new(status: nil, checks: [], error: "no sudo") }

    ServerAuditCheckJob.perform_now(@server.id, auditor: auditor)

    @server.reload
    assert_equal "secure", @server.last_audit_status
    assert_not @server.audit_fresh?, "staleness must be allowed to accrue, not papered over"
  end
end
