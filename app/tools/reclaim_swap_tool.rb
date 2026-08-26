# Reclaim a server's swap through Conductor's vetted wrapper (ServerSwapReclaim).
#
# A first-class action so this never has to be a hand-run `sudo swapoff -a &&
# sudo swapon -a` over SSH. That command is safe exactly when there is RAM to
# hold the evacuated pages and OOM-kills a live box when there isn't — which is
# the kind of judgement that belongs in a guard the caller cannot skip, and in a
# record of who ran it, rather than in whoever is typing.
class ReclaimSwapTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    result = ServerSwapReclaim.new(server).reclaim!
    return Result.fail(result.message) unless result.success?

    # Swap moved, so the stored health rollup is now stale in the operator's
    # favour. Refresh it rather than letting the next read report the number this
    # action just changed.
    begin
      ServerMetrics.new(server).fetch_and_update!
    rescue StandardError
      nil
    end

    Result.ok({
      server:        server.name,
      message:       result.message,
      _organization: server.organization
    })
  end
end
