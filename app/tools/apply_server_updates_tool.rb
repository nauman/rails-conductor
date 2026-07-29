# Apply OS package updates on a server (scope: security | all). Enqueues the
# job and returns immediately; the result streams to the server page. Applying
# "all" (and any kernel update that triggers a reboot) is disruptive — the
# skill enforces the confirm-first gate.
class ApplyServerUpdatesTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    scope = input["scope"] == "all" ? "all" : "security"
    # scope:all is the "may reboot" path — reboot when a kernel update leaves
    # reboot-required, unless the caller opts out. security stays no-reboot.
    reboot = input.key?("reboot") ? (input["reboot"] == true) : (scope == "all")

    server.update!(last_update_status: "running", last_update_scope: scope,
                   last_update_log: nil, last_update_at: Time.current)
    ApplyUpdatesJob.perform_later(server.id, scope, reboot)

    Result.ok({
      server:        server.name,
      scope:         scope,
      status:        "running",
      will_reboot:   reboot,
      message:       "Applying #{scope} updates on #{server.name}#{reboot ? ' (will reboot if a kernel update requires it)' : ''}. " \
                     "Re-run conductor_server action: audit afterwards to confirm.",
      _organization: server.organization
    })
  end
end
