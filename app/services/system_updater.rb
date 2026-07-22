# Applies OS package updates on a server over SSH. Two scopes:
#   security → the standard, already-configured unattended-upgrade (safe; no
#              service bounce for typical security patches)
#   all      → apt-get upgrade (keeps existing configs, doesn't auto-restart via
#              needrestart) — but note upgrading docker/kernel restarts the daemon
#              and briefly bounces containers; the UI warns before this.
class SystemUpdater
  Result = Struct.new(:success, :output, :error, keyword_init: true) do
    def success? = success
  end

  # Packages whose upgrade restarts a daemon or needs a reboot → brief app bounce.
  BOUNCE = /\b(docker-ce|docker-ce-cli|containerd|linux-image|linux-generic|linux-headers|libc6|systemd)\b/

  attr_reader :server, :scope

  def initialize(server, scope: "security", ssh: nil)
    @server = server
    @scope  = %w[security all].include?(scope.to_s) ? scope.to_s : "security"
    @ssh    = ssh || SshConnection.new(server)
  end

  def apply
    return failure("SSH not configured for this server.") unless server.ssh_configured?

    # Updates need root. We run apt via `sudo -n` (non-interactive) — if the SSH
    # user can't sudo without a password, apt dies with a cryptic "sudo: a password
    # is required". Pre-check and return an actionable fix instead of that noise.
    return failure(ServerSudo.remediation(server)) unless ServerSudo.ready?(@ssh)

    res = @ssh.execute_with_status(command)
    output = [res[:stdout], res[:stderr]].map(&:to_s).reject(&:blank?).join("\n").strip
    if res[:success] && res[:exit_code].to_i.zero?
      Result.new(success: true, output: output)
    else
      Result.new(success: false, output: output, error: res[:error].presence || "apt exited #{res[:exit_code]}")
    end
  end

  def command
    if scope == "all"
      "sudo -n DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update -qq && " \
        "sudo -n DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y " \
        "-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade"
    else
      "sudo -n unattended-upgrade -v"
    end
  end

  private

  def failure(message)
    Result.new(success: false, output: nil, error: message)
  end
end
