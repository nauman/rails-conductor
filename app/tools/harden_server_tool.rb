# Hatchbox-style "provision & harden": you add Conductor's key to the box's root,
# Conductor does the rest — creates a deploy user + sudo, hardens SSH/firewall/
# fail2ban, closes an exposed host Postgres, and switches itself to managing the
# box as deploy+sudo. Never locks itself out (root is only surrendered after a
# live deploy+sudo check). Idempotent. Re-run action: audit afterwards to confirm.
class HardenServerTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    result = HardenServer.new(server).call
    return Result.fail(result.error) unless result.ok?

    Result.ok({
      server:        server.name,
      ssh_user:      server.reload.ssh_user,
      audit_status:  result.audit_status,
      steps:         result.steps,
      message:       "#{server.name} hardened; Conductor now manages it as #{server.ssh_user}+sudo. " \
                     "Audit grade: #{result.audit_status || 'unknown'}.",
      _organization: server.organization
    })
  end
end
