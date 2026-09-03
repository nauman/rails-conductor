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

  TOOLS = [ "HAS_UFW:yes", "HAS_SS:yes", "HAS_APT:yes", "HAS_SYSTEMCTL:yes", "HAS_SSHD:yes" ].freeze

  SECURE = ([ "SUDO:yes" ] + TOOLS + [
    "UFW:active", "FAIL2BAN:active", "SSH_ROOT:no", "SSH_PASSWORD:no",
    "SEC_UPDATES:0", "UPDATES:0", "REBOOT:no", "AUTOUPGRADE:active", "DB_PUBLIC:",
    "PROBE_END:ok"
  ]).freeze

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
    result = grade(SECURE.map { |l| l.start_with?("SUDO:") ? "SUDO:no" : l })

    assert_nil result.status, "an unreadable box has no grade"
    assert result.error.present?, "and must say why"
    assert_match(/sudo/i, result.error)
  end

  # Truncated output — a dropped connection mid-probe — must not be graded either.
  test "a truncated probe is inconclusive" do
    result = grade([ "SUDO:yes", "HAS_UFW:yes", "UFW:active" ])

    assert_nil result.status
    assert_match(/incomplete/i, result.error)
  end

  # FALSE SAFETY IS THE WORSE DIRECTION. A missing tool used to read as a clean
  # result: no apt-get meant "zero pending updates", no ss meant "no public
  # database". An absent tool is unknown — never a pass.
  test "a missing tool is unknown, not a pass" do
    lines = SECURE.map { |l| l.start_with?("HAS_SS:") ? "HAS_SS:no" : l }

    db = grade(lines).checks.find { |c| c.key == :db_exposure }
    assert_equal :info, db.status, "no ss must not read as 'not internet-facing'"
    assert_match(/unknown/i, db.detail)
  end

  # And if every check that can BLOCK is unknown, there is no posture at all.
  test "a host where no blocking check can be read is inconclusive, not secure" do
    lines = SECURE.map do |l|
      %w[HAS_UFW: HAS_SS: HAS_SSHD:].any? { |t| l.start_with?(t) } ? l.sub(":yes", ":no") : l
    end

    assert_nil grade(lines).status, "grading secure off the checks that survived would be reassurance by accident"
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
