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
  # The wrapper could not read the box's memory state, so it did nothing.
  UNREADABLE_EXIT_CODE = 4
  # swapoff succeeded and swap could not be brought back. The box is now worse off.
  SWAP_LOST_EXIT_CODE = 5
  # Another reclaim already holds the host lock. Not an error — a correct refusal.
  LOCKED_EXIT_CODE = 6

  # A run that never reported back is treated as finished after this, so a worker
  # that died mid-job cannot wedge the button forever. The host `flock` is what
  # actually prevents an overlap, which is why this can be a plain timeout.
  STALE_AFTER = 15.minutes

  def self.in_flight?(server)
    server.last_swap_reclaim_status == "running" &&
      server.last_swap_reclaim_at.present? &&
      server.last_swap_reclaim_at > STALE_AFTER.ago
  end

  Result = Struct.new(:success, :message, keyword_init: true) do
    def success? = success
  end

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
  end

  def reclaim!
    return failure("SSH not configured for this server.") unless @server.ssh_configured?

    # One door for every privileged op. It tries the deploy user's own sudo before
    # anyone is asked for a credential, so a box provisioned before this wrapper
    # existed heals itself instead of queueing a root errand for a human.
    elevation = ServerSudo.ensure!(@server, @ssh)
    return failure("Cannot reach #{@server.name}: #{elevation.detail}") if elevation.status == :unreachable
    return failure(elevation.detail) unless elevation.usable?

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

    # The wrapper ran, looked at the box, and could not read it. Distinct from a
    # refusal: nothing was attempted, so nothing is half-done.
    return "#{@server.name} could not report its memory state, so Conductor did not touch swap. " \
           "#{stderr.presence || 'free(1) was unreadable.'}" if result[:exit_code].to_i == UNREADABLE_EXIT_CODE

    # The dangerous one, and the reason the wrapper verifies instead of assuming:
    # swap went off and did not come back. Say so loudly — this box is now WORSE
    # off than before the action, and that must never read as a generic failure.
    return "A reclaim is already running on #{@server.name}; this one did nothing. Wait for it " \
           "to finish — a second swapoff over the first is how a swap device gets shed." if result[:exit_code].to_i == LOCKED_EXIT_CODE

    return "URGENT: swap is OFF on #{@server.name} after a reclaim — it was disabled and could not " \
           "be restored. The box has no swap at all until this is fixed. #{stderr}" if result[:exit_code].to_i == SWAP_LOST_EXIT_CODE

    "Could not reclaim swap on #{@server.name}: #{stderr.presence || "exit #{result[:exit_code]}"}"
  end

  def failure(message) = Result.new(success: false, message: message)
end
