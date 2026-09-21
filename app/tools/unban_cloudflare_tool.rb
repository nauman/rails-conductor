# Release fail2ban bans on Cloudflare's published ranges, and add those ranges to
# ignoreip so the ban cannot recur.
#
# REPORT-FIRST, like remove_stray_proxy: a bare call shows what it WOULD unban and
# changes nothing. confirm:true acts.
#
# The privileged wrapper derives Cloudflare's ranges itself and takes no arguments.
# That is the difference between "only Cloudflare is unbanned" being a guarantee
# and being a hope: if the caller supplied the addresses, the confirm-gate would
# be decorative — anything could be released by naming it.
class UnbanCloudflareTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    # HELD pending an independent adversarial audit. The wrapper is not installed
    # on any host (ServerSudo::WRAPPERS_PENDING_AUDIT), so this would fail anyway;
    # refusing here says WHY instead of surfacing a missing-wrapper error.
    if ServerSudo::WRAPPERS_PENDING_AUDIT.include?(ServerSudo::UNBAN_CLOUDFLARE)
      return Result.fail("unban_cloudflare is held pending an independent security audit and is not " \
                         "installed on any host. Use conductor_server action=net_diagnose to see which " \
                         "bans are inside Cloudflare's ranges; release them with " \
                         "`fail2ban-client set <jail> unbanip <ip>` as the deploy user meanwhile.")
    end

    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    diagnosis = HostNetworkDiagnosis.new(server).call
    return Result.fail("Could not read host network state on #{server.name}: #{diagnosis.error}") unless diagnosis.ok?

    unless diagnosis.ranges_known
      return Result.fail("Cloudflare's published ranges could not be fetched, so there is nothing to " \
                         "compare bans against. Refusing to act on an unknown range list.")
    end

    return report(server, diagnosis) unless truthy?(input["confirm"])

    # Refuse to act when the preview said there was nothing to act on. The wrapper
    # also writes Cloudflare's ranges into ignoreip on EVERY jail, and running it
    # after a report that said "nothing to unban" would apply that mutation the
    # preview never mentioned — on sshd among others. A report-first gate whose
    # preview omits the change that always happens is not report-first.
    if diagnosis.cloudflare_banned.empty?
      return Result.ok({
        server: server.name, unbanned: [], confirmed: false,
        message: "Nothing to unban on #{server.name}: no banned address is inside Cloudflare's ranges. " \
                 "Not running the wrapper — it would add Cloudflare's ranges to ignoreip on every jail, " \
                 "which is a change the report did not offer.",
        _organization: server.organization
      })
    end

    perform(server, diagnosis)
  end

  private

  def report(server, diagnosis)
    if diagnosis.cloudflare_banned.empty?
      return Result.ok({
        server: server.name, would_unban: [], confirmed: false,
        message: "No banned address on #{server.name} is inside Cloudflare's ranges. Nothing to unban.",
        _organization: server.organization
      })
    end

    Result.ok({
      server:      server.name,
      would_unban: diagnosis.cloudflare_banned.map { |b| { jail: b.jail, address: b.address } },
      confirmed:   false,
      message:     "Would unban #{diagnosis.cloudflare_banned.size} Cloudflare address(es) on " \
                   "#{server.name} and add Cloudflare's ranges to ignoreip. Re-issue with confirm: true " \
                   "to act. The wrapper re-derives the ranges itself, so it releases only what is " \
                   "inside them at the time it runs.",
      _organization: server.organization
    })
  end

  def perform(server, diagnosis)
    ssh = SshConnection.new(server)
    elevation = ServerSudo.ensure!(server, ssh)
    return Result.fail("Cannot elevate on #{server.name}: #{elevation.detail}") unless elevation.usable?

    outcome = ssh.execute_with_status("sudo -n #{ServerSudo::UNBAN_CLOUDFLARE}")
    unless outcome[:success]
      return Result.fail("unban-cloudflare failed on #{server.name} (exit #{outcome[:exit_code]}): " \
                         "#{outcome[:stderr].presence || outcome[:output]}. Nothing was unbanned — the " \
                         "wrapper refuses rather than acting on a range list it could not verify.")
    end

    Result.ok({
      server:    server.name,
      confirmed: true,
      output:    outcome[:output].to_s,
      expected:  diagnosis.cloudflare_banned.map { |b| { jail: b.jail, address: b.address } },
      message:   "Released Cloudflare bans on #{server.name} and added the ranges to ignoreip. " \
                 "ignoreip is RUNTIME state: add the ranges to jail.local for it to survive a " \
                 "fail2ban restart. Re-run conductor_server action=net_diagnose to confirm.",
      _organization: server.organization
    })
  end

  def truthy?(value) = %w[1 true t yes on].include?(value.to_s.strip.downcase)
end
