require "test_helper"

class HostNetworkDiagnosisTest < ActiveSupport::TestCase
  REPORT = <<~TXT.freeze
    === fail2ban ===
    JAIL sshd currently_banned=3
    BANNED sshd 173.245.48.12
    BANNED sshd 198.51.100.7
    BANNED sshd 2400:cb00::5
    IGNOREIP sshd 127.0.0.1/8
    === ufw ===
    Status: active
  TXT

  setup do
    user = User.create!(email: "net@example.com")
    @org = Organization.create_for(user, name: "Net")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.9", ssh_user: "deploy")
    Rails.cache.delete("cloudflare_ip_ranges")
  end

  teardown { Rails.cache.delete("cloudflare_ip_ranges") }

  test "parses one ban per BANNED line and ignores everything else" do
    bans = HostNetworkDiagnosis.new(@server, ssh: nil).parse_bans(REPORT)

    assert_equal 3, bans.size, "IGNOREIP and JAIL lines must not be read as bans"
    assert_equal %w[173.245.48.12 198.51.100.7 2400:cb00::5], bans.map { |b| b[:address] }
    assert_equal [ "sshd" ], bans.map { |b| b[:jail] }.uniq
  end

  test "an empty report yields no bans rather than raising" do
    assert_empty HostNetworkDiagnosis.new(@server, ssh: nil).parse_bans("")
    assert_empty HostNetworkDiagnosis.new(@server, ssh: nil).parse_bans(nil)
  end

  # The distinction the whole feature turns on: a banned Cloudflare edge explains
  # intermittent 522s; a banned attacker is fail2ban working correctly.
  test "flags only the bans inside Cloudflare ranges" do
    diagnosis = diagnosis_with_ranges(%w[173.245.48.0/20 2400:cb00::/32])
    result = diagnosis.call

    assert result.ok?
    assert result.ranges_known
    assert_equal %w[173.245.48.12 2400:cb00::5], result.cloudflare_banned.map(&:address)
    assert_equal 3, result.banned.size, "every ban is still reported, flagged or not"
  end

  # "Ranges unknown" and "no Cloudflare bans" look identical to a reader and mean
  # opposite things. The caller must be able to tell them apart.
  test "unknown ranges are reported as unknown, not as no Cloudflare bans" do
    diagnosis = diagnosis_with_ranges(%w[173.245.48.0/20])
    # Cache.fetch treats a nil value as a MISS and would re-fetch for real, so the
    # unknown case has to be simulated at the lookup, not in the cache.
    result = diagnosis.stub(:cloudflare_ranges, nil) { diagnosis.call }

    assert result.ok?
    assert_not result.ranges_known, "the caller must know the comparison could not be made"
    assert_empty result.cloudflare_banned
    assert_equal 3, result.banned.size
    assert result.banned.none?(&:cloudflare?), "nothing may be claimed as Cloudflare without the ranges"
  end

  # THE PUBLISHED LIST MUST PASS. Every check below refuses something; this is
  # the one that proves they do not refuse Cloudflare. It is pinned to the real
  # response, /29 and all, because a fixture written from the same assumption as
  # the check cannot contradict it — which is exactly how the v6 floor shipped
  # set to /32, a value the genuine list fails.
  PUBLISHED_V6 = <<~TXT.freeze
    2400:cb00::/32
    2606:4700::/32
    2803:f800::/32
    2405:b500::/32
    2405:8100::/32
    2a06:98c0::/29
    2c0f:f248::/32
  TXT

  test "the real published IPv6 list is accepted" do
    with_body(PUBLISHED_V6) do |diagnosis|
      ranges = diagnosis.send(:fetch_ranges, HostNetworkDiagnosis::IPS_V6)

      assert_equal 7, ranges.size
      assert ranges.any? { |r| r.prefix == 29 }, "the /29 is the whole point of this test"
    end
  end

  # A CORRUPTED RESPONSE IS NOT A SHORTER LIST. The old parser dropped
  # unparseable lines one at a time, so a body of "error / 198.51.100.7/32 /
  # malformed" became an authoritative one-entry range list — and that address,
  # which this suite treats as the attacker, was then reported to the operator as
  # Cloudflare.
  test "a corrupted range response is refused rather than salvaged" do
    with_body("error\n198.51.100.7/32\nmalformed\n") do |diagnosis|
      assert_raises(HostNetworkDiagnosis::RangeFetchError) do
        diagnosis.send(:fetch_ranges, HostNetworkDiagnosis::IPS_V4)
      end
    end
  end

  test "a non-200 response is refused even when the body parses" do
    with_body(PUBLISHED_V6, code: "503") do |diagnosis|
      assert_raises(HostNetworkDiagnosis::RangeFetchError) do
        diagnosis.send(:fetch_ranges, HostNetworkDiagnosis::IPS_V6)
      end
    end
  end

  test "duplicates do not satisfy the minimum prefix count" do
    with_body(([ "198.51.100.7/32" ] * 6).join("\n")) do |diagnosis|
      assert_raises(HostNetworkDiagnosis::RangeFetchError) do
        diagnosis.send(:fetch_ranges, HostNetworkDiagnosis::IPS_V4)
      end
    end
  end

  test "four spellings of one network do not satisfy the minimum" do
    with_body("198.51.100.4/30\n198.51.100.5/30\n198.51.100.6/30\n198.51.100.7/30\n") do |diagnosis|
      error = assert_raises(HostNetworkDiagnosis::RangeFetchError) do
        diagnosis.send(:fetch_ranges, HostNetworkDiagnosis::IPS_V4)
      end

      assert_match(/host bits/, error.message, "say why, not just no")
    end
  end

  test "uppercase and expanded IPv6 spellings are accepted" do
    with_body("2400:CB00:0000::/32\n2606:4700::/32\n2803:F800::/32\n2405:b500::/32\n") do |diagnosis|
      ranges = diagnosis.send(:fetch_ranges, HostNetworkDiagnosis::IPS_V6)

      assert_equal 4, ranges.size, "a host-bits check must not become a spelling check"
    end
  end

  test "the wrong address family is refused" do
    with_body("198.51.100.0/24\n198.51.101.0/24\n198.51.102.0/24\n198.51.103.0/24\n") do |diagnosis|
      assert_raises(HostNetworkDiagnosis::RangeFetchError) do
        diagnosis.send(:fetch_ranges, HostNetworkDiagnosis::IPS_V6)
      end
    end
  end

  test "a prefix broader than Cloudflare publishes is refused" do
    with_body("0.0.0.0/0\n10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16\n") do |diagnosis|
      assert_raises(HostNetworkDiagnosis::RangeFetchError) do
        diagnosis.send(:fetch_ranges, HostNetworkDiagnosis::IPS_V4)
      end
    end
  end

  test "an unusable elevation fails rather than reporting an empty diagnosis" do
    ssh = Object.new
    def ssh.execute_with_status(_cmd) = { success: false, exit_code: 1, output: "", stderr: "no sudo" }

    result = HostNetworkDiagnosis.new(@server, ssh: ssh).call

    assert_not result.ok?
    assert result.error.present?
    assert_empty result.banned
  end

  private

  # STUBBED, NOT CACHED. The test cache is a NullStore, so `Rails.cache.write`
  # here was a no-op and `Rails.cache.fetch` ran its block — meaning this helper
  # quietly made a LIVE request to cloudflare.com on every run, and the tests
  # passed or failed on whatever the internet said that day. That is also why the
  # /32 floor bug survived: the one test that could have caught it was not using
  # the fixture it appeared to be using.
  def diagnosis_with_ranges(cidrs)
    ranges = cidrs&.map { |c| IPAddr.new(c) }
    diagnosis = build_diagnosis
    diagnosis.define_singleton_method(:cloudflare_ranges) { ranges }
    diagnosis
  end

  def build_diagnosis
    ssh = Object.new
    report = REPORT
    ssh.define_singleton_method(:execute_with_status) do |cmd|
      if cmd.include?("conductor-check")
        { success: true, exit_code: 0, output: "", stderr: "" }
      elsif cmd.include?("conductor-net-diagnose")
        { success: true, exit_code: 0, output: report, stderr: "" }
      else
        { success: true, exit_code: 0, output: "", stderr: "" }
      end
    end
    HostNetworkDiagnosis.new(@server, ssh: ssh)
  end

  # A stand-in for the endpoint. Net::HTTP.get_response is what fetch_ranges
  # calls, so that is what is replaced — the parsing and the status check both
  # stay in the test.
  def with_body(body, code: "200")
    response = Struct.new(:code, :body).new(code, body)
    response.define_singleton_method(:is_a?) { |k| k == Net::HTTPSuccess ? code == "200" : super(k) }
    Net::HTTP.stub(:get_response, response) { yield build_diagnosis }
  end
end
