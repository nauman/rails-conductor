# Run Conductor's read-only security/patch audit on a server over SSH and return
# the graded posture (firewall, SSH hardening, DB exposure, pending security
# updates, reboot-required, …). Records the rollup so the deploy preflight can
# read it. Nothing is changed.
class ServerAuditTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    audit = ServerAudit.new(server).audit
    return Result.fail(audit.error) unless audit.ok?

    server.record_audit!(audit.status)

    Result.ok({
      server:        server.name,
      status:        audit.status,
      checks:        audit.checks.map { |c| { check: c.label, status: c.status, detail: c.detail } },
      _organization: server.organization
    })
  end
end
