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

    Result.ok({
      server:        server.name,
      status:        "rebooting",
      message:       "#{result.message} Re-run conductor_server action: audit after it's back to confirm.",
      _organization: server.organization
    })
  end
end
