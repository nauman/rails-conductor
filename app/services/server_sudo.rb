# Shared passwordless-sudo helpers. Privileged fleet ops (updates, reboot) run as
# the SSH user via `sudo -n`; this is the one place that probes for the NOPASSWD
# grant and prints the one-time fix — the same grant Hatchbox sets up at provision
# time, so no permanent root SSH is needed.
module ServerSudo
  module_function

  # The commands Conductor needs to run as root, scoped in the sudoers grant.
  SUDO_COMMANDS = "/usr/bin/apt-get, /usr/bin/unattended-upgrade, /usr/sbin/unattended-upgrade, /sbin/reboot, /usr/sbin/reboot".freeze

  def ready?(ssh)
    res = ssh.execute_with_status("sudo -n true")
    res[:success] && res[:exit_code].to_i.zero?
  end

  # The exact sudoers line for this server's SSH user.
  def grant_command(server)
    user = server.ssh_user_or_default
    "echo '#{user} ALL=(ALL) NOPASSWD: #{SUDO_COMMANDS}' | sudo tee /etc/sudoers.d/conductor >/dev/null && sudo chmod 440 /etc/sudoers.d/conductor"
  end

  def remediation(server)
    user = server.ssh_user_or_default
    "Conductor needs passwordless sudo to run privileged ops as '#{user}', but this server " \
    "prompts for a password (sudo: a password is required).\n\n" \
    "Fix it once — as root (or a sudo user) on the server, run:\n" \
    "  #{grant_command(server)}\n\n" \
    "Then retry. This is the same one-time grant Hatchbox sets up during provisioning — " \
    "no permanent root SSH needed."
  end
end
