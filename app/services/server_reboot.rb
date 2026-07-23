# Reboots a server over SSH (sudo -n). Pre-checks passwordless sudo so the operator
# gets the one-time fix instead of a cryptic sudo error. Issuing the reboot drops
# the connection as the box goes down — that's expected, not a failure.
class ServerReboot
  Result = Struct.new(:success, :message, keyword_init: true) do
    def success? = success
  end

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
  end

  def reboot!
    return failure("SSH not configured for this server.") unless @server.ssh_configured?
    return failure(ServerSudo.remediation(@server)) unless ServerSudo.ready?(@ssh)

    # Run the vetted root-owned reboot wrapper (systemctl reboot). The command is
    # accepted, then the connection drops — we don't read success from that.
    @ssh.execute_with_status("sudo -n #{ServerSudo::REBOOT}")
    Result.new(success: true,
               message: "Reboot sent to #{@server.name}. It will drop offline for a moment and come back.")
  end

  private

  def failure(message) = Result.new(success: false, message: message)
end
