require "test_helper"

# `audit_fresh?(within: 7.days)` existed and the deploy preflight already used it
# correctly — a stale `secure` degrades to a warning rather than clearing a deploy.
#
# But nothing ever made an audit fresh again except a human running one, so
# freshness could only decay. One server's grade was five weeks old while the
# preflight gated deploys on it: an `at_risk` from July blocks a box that may have
# been fixed, and a `secure` from July clears one that may have rotted.
#
# The logic was never the gap. The refresh was (ADR 0010).
class ServerAuditCheckJobTest < ActiveJob::TestCase
  setup do
    user = User.create!(email: "aud@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.20",
                                   ssh_key: @key, ssh_user: "deploy")
    @server.update_columns(last_audit_status: "at_risk", last_audit_at: 40.days.ago)
  end

  class FakeAuditor
    def initialize(result) = @result = result
    def audit = @result
  end

  def result(status) = ServerAudit::Result.new(status: status, checks: [], error: nil)

  test "the sweep enqueues one job per server" do
    @org.servers.create!(name: "box2", status: "online", ip_address: "10.0.0.21", ssh_key: @key)

    assert_enqueued_jobs 2, only: ServerAuditCheckJob do
      ServerAuditCheckJob.sweep
    end
  end

  test "a successful audit records the grade and moves the timestamp" do
    ServerAuditCheckJob.perform_now(@server.id, auditor: FakeAuditor.new(result(:secure)))

    @server.reload
    assert_equal "secure", @server.last_audit_status
    assert @server.audit_fresh?, "an audit that just ran must read as fresh"
  end

  # Fail toward stale, never toward a better grade. A box that cannot be reached is
  # not a box that became secure, and this runs unattended.
  test "an unreachable server keeps its previous grade rather than being upgraded" do
    failed = ServerAudit::Result.new(status: nil, checks: [], error: "SSH not configured")

    ServerAuditCheckJob.perform_now(@server.id, auditor: FakeAuditor.new(failed))

    @server.reload
    assert_equal "at_risk", @server.last_audit_status, "a failed probe must not clear a risk grade"
    assert_not @server.audit_fresh?, "and must not refresh the timestamp it could not verify"
  end

  test "a raised error is contained and leaves the grade untouched" do
    raiser = Object.new
    raiser.define_singleton_method(:audit) { raise "boom" }

    assert_nothing_raised { ServerAuditCheckJob.perform_now(@server.id, auditor: raiser) }
    assert_equal "at_risk", @server.reload.last_audit_status
  end

  test "a deleted server is a no-op" do
    id = @server.id
    @server.destroy

    assert_nothing_raised { ServerAuditCheckJob.perform_now(id) }
  end
end
