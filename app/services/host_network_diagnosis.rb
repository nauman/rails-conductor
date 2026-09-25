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

  # Raised when a range response is not the published list. Rescued by
  # #cloudflare_ranges into nil, which reads as "ranges unknown" — never as
  # "no ranges", which would report every ban as not-Cloudflare.
  RangeFetchError = Class.new(StandardError)

  CIDR_SHAPE   = /\A[0-9a-fA-F:.]+\/[0-9]{1,3}\z/
  MIN_PREFIXES = 4      # Cloudflare publishes 15 v4 and 7 v6; fewer is a truncated transfer

  # TAKEN FROM THE PUBLISHED LIST, not from an intuition about it. Their broadest
  # blocks today are /13 (104.16.0.0/13) and /29 (2a06:98c0::/29). The v6 floor
  # was /32 — which the REAL list fails, because a /29 is broader than a /32. So
  # the check that exists to refuse an implausible list would have refused the
  # genuine one, every time, on every server. Found by running it against the
  # endpoint rather than against a fixture written from the same assumption.
  #
  # A couple of steps of headroom, so a new Cloudflare block does not break this
  # again, and still far from anything that would exempt swathes of the internet.
  BROADEST_V4  = 10
  BROADEST_V6  = 27
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

  # WHOLE-LIST, NOT LINE-BY-LINE, and the status code is read.
  #
  # The old version called `Net::HTTP.get` (which discards the status) and
  # dropped unparseable lines individually. An audit fed it a body of
  # "error\n198.51.100.7/32\nmalformed" and got back a one-entry range list that
  # was then treated as authoritative — so a non-Cloudflare address was reported
  # to the operator as Cloudflare, which is the address they would then release.
  # A salvaged fragment of a bad response is not a shorter published list; it is
  # evidence the response is not the published list at all.
  #
  # These thresholds mirror the wrapper's deliberately. Two places decide what
  # counts as Cloudflare — the privileged script and this report — and they have
  # to fail on the same inputs, or the preview stops describing the action.
  def fetch_ranges(url)
    response = Net::HTTP.get_response(URI(url))
    unless response.is_a?(Net::HTTPSuccess)
      raise RangeFetchError, "#{url} answered #{response.code}"
    end

    lines = response.body.to_s.delete("\uFEFF").split("\n")
                     .map(&:strip).reject { |l| l.empty? || l.start_with?("#") }

    ranges = lines.map do |cidr|
      raise RangeFetchError, "#{url} returned a line that is not a CIDR" unless cidr.match?(CIDR_SHAPE)

      range = begin
        IPAddr.new(cidr)
      rescue IPAddr::Error
        raise RangeFetchError, "#{url} returned a line that is not a CIDR"
      end

      # HOST BITS SET IS NOT A PREFIX. IPAddr masks them away silently, so
      # 198.51.100.4/30 through .7/30 arrive as four lines that are one network.
      # The published list never does this; a list that does is not it.
      unless range.to_s == cidr.split("/").first
        raise RangeFetchError, "#{url} returned #{cidr}, which has host bits set"
      end

      range
    end

    # Uniqueness by NETWORK — address and prefix together. Counting spellings
    # lets four ways of writing one block satisfy a minimum-count check while
    # carrying a single address.
    ranges.uniq! { |r| [ r.to_s, r.prefix ] }

    if ranges.size < MIN_PREFIXES
      raise RangeFetchError, "#{url} returned only #{ranges.size} distinct prefixes"
    end

    # The v4 endpoint must answer with v4. Without this, a substituted response
    # satisfies the v6 floor with v4 prefixes, or the reverse.
    want = url == IPS_V6 ? Socket::AF_INET6 : Socket::AF_INET
    unless ranges.all? { |r| r.family == want }
      raise RangeFetchError, "#{url} returned prefixes of the wrong address family"
    end

    floor = want == Socket::AF_INET6 ? BROADEST_V6 : BROADEST_V4
    if ranges.any? { |r| r.prefix < floor }
      raise RangeFetchError, "#{url} contains a prefix broader than Cloudflare publishes"
    end

    ranges
  end

  def failure(detail) = Result.new(ok: false, error: detail, banned: [], cloudflare_banned: [], ranges_known: false)
end
