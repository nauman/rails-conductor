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

    # Harden takes minutes (apt installs, a Postgres restart, an sshd reload), so
    # it runs as a background job — a synchronous call would blow the gateway
    # timeout. Returns immediately; poll conductor_server action: audit to confirm.
    server.update!(last_harden_status: "running", last_harden_at: Time.current, last_harden_log: nil)
    HardenServerJob.perform_later(server.id)

    Result.ok({
      server:        server.name,
      status:        "running",
      message:       "Hardening #{server.name} in the background (provision deploy+sudo → ufw/fail2ban → " \
                     "disable root/password → close exposed DB → switch to deploy). It never self-locks. " \
                     "Poll conductor_server action: audit in ~2 min to confirm it flips to secure/attention.",
      _organization: server.organization
    })
  end
end
