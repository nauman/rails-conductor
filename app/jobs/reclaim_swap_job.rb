# Reclaim a server's swap OUT OF THE REQUEST CYCLE.
#
# This job exists because of a live incident, and the reason is worth keeping:
# the reclaim ran inside an MCP request, the proxy returned 504 before the SSH
# chain finished, and the request was severed mid-`swapoff -a`. One device had
# already been evacuated; `swapon -a` and the wrapper's restore loop never ran.
# The box came out of it with 471 MiB LESS swap than it started with — the exact
# opposite of the operation's purpose.
#
# The wrapper's internal restore logic could not have saved it. No amount of care
# inside a script survives the script's process being killed halfway. The category
# error was running an interruptible, stateful, privileged operation somewhere it
# could be interrupted: `swapoff` reads gigabytes back from disk, and any HTTP
# timeout shorter than that is a hazard, not an edge case.
#
# An interrupted deploy is retryable. An interrupted swapoff leaves a degraded
# box. If anything belongs in a job, it is this.
class ReclaimSwapJob < ApplicationJob
  queue_as :ops

  def perform(server_id)
    server = Server.find_by(id: server_id)
    return unless server

    result = ServerSwapReclaim.new(server).reclaim!

    server.update!(
      last_swap_reclaim_status: result.success? ? "succeeded" : "failed",
      last_swap_reclaim_log:    result.message.to_s.last(20_000),
      last_swap_reclaim_at:     Time.current
    )

    # Swap moved, so the stored metrics now under-report the box in the operator's
    # favour. Refresh rather than letting the next read show the figure this job
    # just changed. Never fatal: the reclaim already happened.
    begin
      ServerMetrics.new(server).fetch_and_update!
    rescue StandardError
      nil
    end
  end
end
