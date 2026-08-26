# Reclaim a box's swap: force every swapped-out page back into RAM, then bring
# swap up empty again.
#
# WHY THIS EXISTS AS AN ACTION. Linux never pages swap back in on its own. A page
# evicted during one bad minute stays in swap until some process happens to touch
# it, so a box that survived a memory spike reads "swap 100% used" for weeks
# afterwards while RAM sits mostly free. That number is a record of PAST pressure,
# not current pressure — and the health check cannot tell the two apart, because
# from the outside they look identical.
#
# What it costs is real though: a box with swap already full has no headroom for
# the NEXT spike, which is how one bad minute becomes two.
#
# THE DANGER, and why this is a wrapper and not an ad-hoc SSH command: `swapoff`
# must find somewhere to put every page it evacuates. Run it when RAM is tight and
# the kernel reaches for the OOM killer on a live box — trading a cosmetic metric
# for a real outage. The headroom guard lives inside the root-owned wrapper, where
# the deploy user cannot pass a flag to skip it.
class ServerSwapReclaim
  # The wrapper's own "I checked and it isn't safe" code, distinct from a generic
  # failure. Kept in sync with ServerSudo::RECLAIM_SWAP.
  REFUSED_EXIT_CODE = 3

  Result = Struct.new(:success, :message, keyword_init: true) do
    def success? = success
  end

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
  end

  def reclaim!
    return failure("SSH not configured for this server.") unless @server.ssh_configured?
    return failure(ServerSudo.remediation(@server)) unless ServerSudo.ready?(@ssh)

    result = @ssh.execute_with_status("sudo -n #{ServerSudo::RECLAIM_SWAP}")
    return Result.new(success: true, message: success_message(result)) if result[:success]

    failure(failure_message(result))
  end

  private

  def success_message(result)
    detail = result[:stdout].to_s.strip.presence || "done"
    "Swap reclaimed on #{@server.name}: #{detail}. Swap is back up and empty, so the " \
    "next memory spike has somewhere to go."
  end

  def failure_message(result)
    stderr = result[:stderr].to_s.strip

    # The wrapper looked and said no. Pass its own numbers through — "not enough
    # free RAM" with the figures is actionable; a bare exit code is not.
    if result[:exit_code].to_i == REFUSED_EXIT_CODE
      return "#{@server.name} has too much in swap to reclaim safely right now — not enough " \
             "free RAM to hold the evacuated pages, so swapoff would invoke the OOM killer. " \
             "#{stderr.presence || 'The wrapper refused.'} Free memory first, or reboot the box instead."
    end

    # A server granted before this wrapper shipped passes the readiness probe
    # (which only exercises conductor-check) and then trips here. That is a
    # provisioning gap, so hand over the one-time re-grant rather than the raw error.
    if stderr.match?(/command not found|No such file|not allowed to execute/i)
      return "#{@server.name} was prepared before Conductor had a swap-reclaim wrapper, so " \
             "#{ServerSudo::RECLAIM_SWAP} isn't installed yet.\n\n#{ServerSudo.remediation(@server)}"
    end

    "Could not reclaim swap on #{@server.name}: #{stderr.presence || "exit #{result[:exit_code]}"}"
  end

  def failure(message) = Result.new(success: false, message: message)
end
