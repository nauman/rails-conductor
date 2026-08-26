# Reclaim a server's swap through Conductor's vetted wrapper. Enqueues the job
# and returns immediately; the result lands on the server record and page.
#
# A first-class action so this never has to be a hand-run `sudo swapoff -a &&
# sudo swapon -a` over SSH. That command is safe exactly when there is RAM to
# hold the evacuated pages and OOM-kills a live box when there isn't — the kind
# of judgement that belongs in a guard the caller cannot skip, and in a record of
# who ran it, rather than in whoever is typing.
#
# It returns rather than waits for a second reason, learned the hard way: running
# this synchronously let a proxy timeout sever the SSH mid-swapoff and leave a box
# with less swap than it started with. See ReclaimSwapJob.
class ReclaimSwapTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    server.update!(last_swap_reclaim_status: "running", last_swap_reclaim_log: nil,
                   last_swap_reclaim_at: Time.current)
    ReclaimSwapJob.perform_later(server.id)

    Result.ok({
      server:        server.name,
      status:        "running",
      message:       "Reclaiming swap on #{server.name} in the background. Nothing restarts, and " \
                     "Conductor refuses if there isn't RAM to hold the evacuated pages. " \
                     "Read conductor_read action: server to see the outcome — do NOT re-issue " \
                     "this while it runs: a second swapoff over the first can shed a device.",
      _organization: server.organization
    })
  end
end
