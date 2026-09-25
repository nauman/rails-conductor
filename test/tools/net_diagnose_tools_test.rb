require "test_helper"

# Neither tool had a test. The confirm gate, the unknown-ranges refusal, and the
# "nothing to unban" path are the three places a mistake releases firewall bans or
# silently exempts addresses — exactly the code that must not be trusted to
# inspection.
class NetDiagnoseToolsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "tools@example.com")
    @org = Organization.create_for(@user, name: "Tools")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.9", ssh_user: "deploy")
  end

  # A diagnosis double, so these test the TOOL's decisions rather than SSH.
  def diagnosis(ok: true, banned: [], cloudflare: [], ranges_known: true, error: nil)
    bans = ->(list) { list.map { |a| HostNetworkDiagnosis::Ban.new(jail: "sshd", address: a, cloudflare: cloudflare.include?(a)) } }
    HostNetworkDiagnosis::Result.new(
      ok: ok, report: "=== fail2ban ===", banned: bans.call(banned),
      cloudflare_banned: bans.call(cloudflare), ranges_known: ranges_known, error: error
    )
  end

  def with_diagnosis(result)
    HostNetworkDiagnosis.stub(:new, ->(*) { Struct.new(:call).new(result) }) { yield }
  end

  # unban_cloudflare is held pending an independent audit, so its own logic is
  # unreachable through the tool. The logic still has to be tested — a held
  # capability that nobody exercises is one that rots before it is released, and
  # the audit needs it working. This lifts the hold for the duration of a test.
  def with_hold_lifted
    ServerSudo.stub_const_pending_audit([]) { yield }
  end

  test "net_diagnose reports the Cloudflare bans it found" do
    with_diagnosis(diagnosis(banned: %w[173.245.48.12 198.51.100.7], cloudflare: %w[173.245.48.12])) do
      out = NetDiagnoseTool.new(user: @user).call("server_id" => @server.id)

      assert out.success?
      assert_equal 2, out.value[:banned_count]
      assert_equal [ "173.245.48.12" ], out.value[:cloudflare_banned].map { |b| b[:address] }
      assert_match(/inside Cloudflare's ranges/, out.value[:verdict])
      assert out.value[:next_step].present?, "a Cloudflare ban should point at the unban action"
    end
  end

  # "Ranges unknown" and "no Cloudflare bans" must never read the same.
  test "net_diagnose says UNKNOWN rather than clean when the ranges could not be fetched" do
    with_diagnosis(diagnosis(banned: %w[198.51.100.7], ranges_known: false)) do
      out = NetDiagnoseTool.new(user: @user).call("server_id" => @server.id)

      assert out.success?
      assert_not out.value[:cloudflare_ranges_known]
      assert_match(/UNKNOWN, not clean/, out.value[:verdict])
    end
  end

  # The verdict must not claim more than containment can measure.
  test "net_diagnose does not claim a network ban was checked" do
    with_diagnosis(diagnosis(banned: %w[198.51.100.7])) do
      verdict = NetDiagnoseTool.new(user: @user).call("server_id" => @server.id).value[:verdict]

      assert_match(/no single banned address/, verdict)
      assert_match(/NETWORK overlapping Cloudflare is not\s+detected/i, verdict.gsub(/\s+/, " ").then { |v| v })
    end
  end

  test "unban without confirm reports and changes nothing" do
    with_hold_lifted { with_diagnosis(diagnosis(banned: %w[173.245.48.12], cloudflare: %w[173.245.48.12])) do
      out = UnbanCloudflareTool.new(user: @user).call("server_id" => @server.id)

      assert out.success?
      assert_not out.value[:confirmed]
      assert_equal [ "173.245.48.12" ], out.value[:would_unban].map { |b| b[:address] }
      assert_match(/confirm: true/, out.value[:message])
    end }
  end

  # The wrapper writes Cloudflare's ranges into ignoreip on EVERY jail. Running it
  # after a report that said "nothing to unban" applies a change the preview never
  # offered — including on sshd.
  test "unban with confirm does nothing when there is nothing to unban" do
    with_hold_lifted { with_diagnosis(diagnosis(banned: %w[198.51.100.7])) do
      out = UnbanCloudflareTool.new(user: @user).call("server_id" => @server.id, "confirm" => true)

      assert out.success?
      assert_not out.value[:confirmed], "the wrapper must not run when the preview offered nothing"
      assert_match(/Not running the wrapper/, out.value[:message])
      assert_match(/ignoreip/, out.value[:message], "the message should say what it declined to change")
    end }
  end

  # Acting on a range list that could not be verified is the failure mode the
  # whole design exists to avoid.
  test "unban refuses entirely when the Cloudflare ranges are unknown" do
    with_hold_lifted { with_diagnosis(diagnosis(banned: %w[173.245.48.12], ranges_known: false)) do
      out = UnbanCloudflareTool.new(user: @user).call("server_id" => @server.id, "confirm" => true)

      assert_not out.success?
      assert_match(/could not be fetched/, out.error)
    end }
  end

  # THE HOLD, exercised with something held. unban_cloudflare was released on
  # 2026-09-25 after three adversarial rounds, so the list is empty — and a
  # refusal path only tested while something happens to be in it is a refusal
  # path that rots. The tool reads the list rather than naming a wrapper, so
  # this is the behaviour any future hold will produce.
  test "a tool whose wrapper is held pending audit refuses, and says what can be done instead" do
    ServerSudo.stub_const_pending_audit([ ServerSudo::UNBAN_CLOUDFLARE ]) do
      out = UnbanCloudflareTool.new(user: @user).call("server_id" => @server.id, "confirm" => true)

      assert_not out.success?
      assert_match(/held pending an independent security audit/, out.error)
      assert_match(/net_diagnose/, out.error, "the refusal should name what the operator CAN do")
    end
  end

  # And the release itself, asserted — so reverting it silently is a red test
  # rather than a capability that quietly stops existing.
  test "unban_cloudflare is released and installed" do
    assert_empty ServerSudo::WRAPPERS_PENDING_AUDIT
    assert_includes ServerSudo::WRAPPERS, ServerSudo::UNBAN_CLOUDFLARE
  end

  test "both tools fail cleanly when the host cannot be read" do
    with_diagnosis(diagnosis(ok: false, error: "no sudo")) do
      assert_not NetDiagnoseTool.new(user: @user).call("server_id" => @server.id).success?
      assert_not UnbanCloudflareTool.new(user: @user).call("server_id" => @server.id).success?
    end
  end
end
