# Read host network state, and answer the one question a Cloudflare 522
# investigation always ends on: is anything Cloudflare uses currently banned?
#
# Conductor could already see that a site was failing and that the box was healthy.
# It could not see fail2ban or ufw, because those are host state and every path it
# had — `conductor_app runner`, `run_script`, raw SSH — either runs in the
# container, runs only canned scripts, or is blocked for agents. So the
# investigation ended with "ask the founder to SSH in", which is the outcome
# ServerSudo exists to make unnecessary.
#
# The Cloudflare comparison lives HERE rather than in the wrapper on purpose. A
# root-owned script that reaches out to the internet on every call is a much
# larger surface than one that prints local state, and doing it here means the
# range list can be cached and is visible in Conductor's own logs.
class HostNetworkDiagnosis
  IPS_V4 = "https://www.cloudflare.com/ips-v4".freeze
  IPS_V6 = "https://www.cloudflare.com/ips-v6".freeze
  RANGE_TTL = 12.hours

  Result = Struct.new(:ok, :report, :banned, :cloudflare_banned, :ranges_known, :error, keyword_init: true) do
    def ok? = ok
    def cloudflare_bans? = cloudflare_banned.present?
  end

  Ban = Struct.new(:jail, :address, :cloudflare, keyword_init: true) do
    def cloudflare? = cloudflare
  end

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
  end

  def call
    elevation = ServerSudo.ensure!(@server, @ssh)
    return failure("Cannot reach #{@server.name}: #{elevation.detail}") if elevation.status == :unreachable
    return failure(elevation.detail) unless elevation.usable?

    outcome = @ssh.execute_with_status("sudo -n #{ServerSudo::NET_DIAGNOSE}")
    return failure(outcome[:stderr].presence || "net-diagnose failed (exit #{outcome[:exit_code]})") unless outcome[:success]

    report = outcome[:output].to_s
    bans = parse_bans(report)
    ranges = cloudflare_ranges

    # If the ranges are unknown, say so rather than reporting "no Cloudflare bans".
    # Those two look identical to a reader and mean opposite things.
    annotated = bans.map { |b| Ban.new(jail: b[:jail], address: b[:address], cloudflare: ranges && in_ranges?(b[:address], ranges)) }

    Result.new(ok: true, report: report, banned: annotated,
               cloudflare_banned: annotated.select(&:cloudflare?), ranges_known: !ranges.nil?)
  end

  # BANNED <jail> <address>, one line per address — the shape the wrapper emits so
  # nothing here has to parse fail2ban's prose, which differs across versions.
  def parse_bans(report)
    report.to_s.lines.filter_map do |line|
      next unless (m = line.match(/\ABANNED\s+(\S+)\s+(\S+)\s*\z/))

      { jail: m[1], address: m[2] }
    end
  end

  private

  def in_ranges?(address, ranges)
    ip = IPAddr.new(address)
    ranges.any? { |r| r.include?(ip) }
  rescue IPAddr::Error
    false
  end

  # Cached: the list moves rarely, and an incident is not the time to depend on a
  # third-party fetch succeeding. nil means "unknown", never "empty" — an empty
  # list would silently report every ban as not-Cloudflare.
  def cloudflare_ranges
    Rails.cache.fetch("cloudflare_ip_ranges", expires_in: RANGE_TTL) do
      parsed = [ IPS_V4, IPS_V6 ].flat_map { |url| fetch_ranges(url) }
      parsed.presence
    end
  rescue StandardError => e
    Rails.logger.warn("[HostNetworkDiagnosis] could not load Cloudflare ranges: #{e.message}")
    nil
  end

  def fetch_ranges(url)
    body = Net::HTTP.get(URI(url))
    body.to_s.split("\n").filter_map do |line|
      cidr = line.strip
      next if cidr.empty?

      begin
        IPAddr.new(cidr)
      rescue IPAddr::Error
        nil
      end
    end
  end

  def failure(detail) = Result.new(ok: false, error: detail, banned: [], cloudflare_banned: [], ranges_known: false)
end
