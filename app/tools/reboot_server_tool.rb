# Reboot a managed server via Conductor's vetted reboot wrapper (ServerReboot).
# A first-class MCP action so a reboot never falls back to a raw, guardrail-blocked
# `sudo reboot` — e.g. to activate a kernel installed by apply_updates. Disruptive
# (briefly downs the server's apps; those with restart policies come back) — confirm.
class RebootServerTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    result = ServerReboot.new(server).reboot!
    return Result.fail(result.message) unless result.success?

    # Reflect the reboot in the record immediately (transitional state + grace
    # window), so the UI shows "rebooting" now — not "online" until a poll fails
    # (which would also fire a false offline alert).
    server.mark_rebooting!

    # Babysit recovery: after the box returns, verify + remediate its apps rather
    # than leaving a crashed container / stale port to a human (a short initial
    # delay lets the box actually start going down first).
    RebootRecoveryJob.set(wait: 60.seconds).perform_later(server.id)

    Result.ok({
      server:        server.name,
      status:        "rebooting",
      message:       "#{result.message} Conductor will babysit recovery (verify + restart apps once it's back).",
      _organization: server.organization
    })
  end
end
