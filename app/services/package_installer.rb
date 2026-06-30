# Installs apt packages on a server over SSH. General-purpose: the caller supplies
# any package list. Privileged op — runs via `sudo -n` (works whether the SSH user
# is root or a sudo-capable deploy user; fails fast if sudo needs a password rather
# than hanging). Package names are strictly validated to prevent shell injection.
class PackageInstaller
  Result = Struct.new(:success, :output, :error, :packages, keyword_init: true) do
    def success? = success
  end

  # An apt token: name (lowercase apt convention), optional :arch and =version.
  VALID = /\A[a-z0-9][a-z0-9+.\-]*(?::[a-z0-9]+)?(?:=[a-zA-Z0-9.+:~\-]+)?\z/

  attr_reader :server, :packages, :error

  def initialize(server, packages, ssh: nil)
    @server = server
    @packages = Array(packages).flat_map { |p| self.class.parse_list(p) }.uniq
    @ssh = ssh || SshConnection.new(server)
    @error = nil
  end

  # Split a free-form field ("git curl, build-essential") into tokens.
  def self.parse_list(raw)
    raw.to_s.split(/[\s,]+/).map(&:strip).reject(&:blank?)
  end

  def install
    return failure("No packages given.") if packages.empty?

    invalid = packages.reject { |p| p.match?(VALID) }
    return failure("Invalid package name(s): #{invalid.join(', ')}") if invalid.any?
    return failure("SSH not configured for this server.") unless server.ssh_configured?

    res = @ssh.execute_with_status(command)
    output = [res[:stdout], res[:stderr]].map(&:to_s).reject(&:blank?).join("\n").strip

    if res[:success] && res[:exit_code].to_i.zero?
      Result.new(success: true, output: output, packages: packages)
    else
      detail = res[:error].presence || "apt-get exited #{res[:exit_code]}"
      Result.new(success: false, output: output, error: detail, packages: packages)
    end
  end

  # `apt-get update` then a non-interactive install. sudo -n so a password prompt
  # errors instead of hanging the connection.
  def command
    list = packages.join(" ")
    "sudo -n DEBIAN_FRONTEND=noninteractive apt-get update && " \
      "sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y #{list}"
  end

  private

  def failure(message)
    @error = message
    Result.new(success: false, output: nil, error: message, packages: packages)
  end
end
