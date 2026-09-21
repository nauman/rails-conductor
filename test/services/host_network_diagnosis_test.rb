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

  test "an unusable elevation fails rather than reporting an empty diagnosis" do
    ssh = Object.new
    def ssh.execute_with_status(_cmd) = { success: false, exit_code: 1, output: "", stderr: "no sudo" }

    result = HostNetworkDiagnosis.new(@server, ssh: ssh).call

    assert_not result.ok?
    assert result.error.present?
    assert_empty result.banned
  end

  private

  def diagnosis_with_ranges(cidrs)
    Rails.cache.write("cloudflare_ip_ranges", cidrs&.map { |c| IPAddr.new(c) })

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
end
