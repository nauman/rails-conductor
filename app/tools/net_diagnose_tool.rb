# Read host network state: fail2ban bans, ufw rules, edge container, conntrack and
# listen-queue drops — and flag any ban inside Cloudflare's published ranges.
#
# Exists because a Cloudflare 522 investigation ended with "ask the founder to SSH
# in". Everything else was already visible through Conductor; the host firewall was
# not, and that is exactly where the answer was.
class NetDiagnoseTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    result = HostNetworkDiagnosis.new(server).call
    return Result.fail("Could not read host network state on #{server.name}: #{result.error}") unless result.ok?

    Result.ok({
      server:        server.name,
      report:        result.report,
      banned_count:  result.banned.size,
      cloudflare_banned: result.cloudflare_banned.map { |b| { jail: b.jail, address: b.address } },
      cloudflare_ranges_known: result.ranges_known,
      verdict:       verdict(result),
      next_step:     next_step(result),
      _organization: server.organization
    })
  end

  private

  # Lead with the answer, not the report. The reader is mid-incident.
  def verdict(result)
    unless result.ranges_known
      return "Cloudflare's published ranges could not be fetched, so no ban was compared against them. " \
             "#{result.banned.size} address(es) are banned — the comparison is UNKNOWN, not clean."
    end
    if result.cloudflare_bans?
      "#{result.cloudflare_banned.size} banned address(es) are inside Cloudflare's ranges. " \
        "That drops a subset of edge connections and looks exactly like intermittent 522s while the " \
        "origin answers directly."
    elsif result.banned.any?
      # "No SINGLE ADDRESS is inside the ranges" is what was measured. A ban on a
      # NETWORK that overlaps Cloudflare is not detected by containment, so the
      # stronger claim would assert something the comparison cannot support.
      "#{result.banned.size} address(es) are banned; no single banned address is inside Cloudflare's " \
        "ranges — that is fail2ban working. Note a ban on a NETWORK overlapping Cloudflare is not " \
        "detected here; check the report's BANNED lines for anything in CIDR form. If the site is " \
        "failing through Cloudflare, look at conntrack and the listen queue."
    else
      "Nothing is banned. If the site is failing through Cloudflare, look at conntrack and the listen " \
        "queue in the report above, then at the edge container."
    end
  end

  def next_step(result)
    return "conductor_server action=unban_cloudflare server_id=… (report-first; add confirm:true to act)" if result.cloudflare_bans?

    nil
  end
end
