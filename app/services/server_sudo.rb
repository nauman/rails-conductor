# Least-privilege privileged-ops setup. Fleet ops (updates, reboot) need root; we
# run them as the SSH user via `sudo -n`. Rather than granting NOPASSWD on general
# tools like apt-get (a documented GTFOBins shell-escape — /docs/privileged-ops),
# Conductor grants NOPASSWD ONLY on a few root-owned wrapper scripts that hardcode
# the exact operation with no argument passthrough. The deploy user can trigger the
# vetted actions but cannot inject flags or spawn a root shell.
#
# One-time root setup installs the wrappers + the sudoers rule (grant_command).
module ServerSudo
  module_function

  WRAPPER_DIR      = "/usr/local/sbin".freeze
  CHECK            = "#{WRAPPER_DIR}/conductor-check".freeze                    # no-op readiness probe
  SECURITY_UPDATES = "#{WRAPPER_DIR}/conductor-apply-security-updates".freeze
  ALL_UPDATES      = "#{WRAPPER_DIR}/conductor-apply-all-updates".freeze
  REBOOT           = "#{WRAPPER_DIR}/conductor-reboot".freeze
  WRAPPERS         = [ CHECK, SECURITY_UPDATES, ALL_UPDATES, REBOOT ].freeze
  SUDOERS_FILE     = "/etc/sudoers.d/conductor".freeze

  # Ready when the SSH user can run the no-op wrapper via passwordless sudo — proves
  # the grant is installed without running (or being able to run) anything else.
  def ready?(ssh)
    res = ssh.execute_with_status("sudo -n #{CHECK}")
    res[:success] && res[:exit_code].to_i.zero?
  end

  # One-time, root-run setup: writes the wrapper scripts (root-owned, 0755 — not
  # writable by the deploy user) and a sudoers rule granting NOPASSWD on exactly
  # those wrappers for this server's SSH user. No permanent root SSH; no shell escape.
  def grant_command(server, user: nil)
    user ||= server.ssh_user_or_default
    <<~SH.strip
      sudo install -d -m 0755 #{WRAPPER_DIR}
      sudo tee #{CHECK} >/dev/null <<'CONDUCTOR'
      #!/bin/sh
      exit 0
      CONDUCTOR
      sudo tee #{SECURITY_UPDATES} >/dev/null <<'CONDUCTOR'
      #!/bin/sh
      set -e
      exec unattended-upgrade -v
      CONDUCTOR
      sudo tee #{ALL_UPDATES} >/dev/null <<'CONDUCTOR'
      #!/bin/sh
      set -e
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
      apt-get update -qq
      exec apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade
      CONDUCTOR
      sudo tee #{REBOOT} >/dev/null <<'CONDUCTOR'
      #!/bin/sh
      # Schedule a few seconds out so the triggering SSH command returns cleanly
      # instead of dying with the connection as the box goes down.
      exec systemd-run --quiet --on-active=3s --timer-property=AccuracySec=100ms systemctl reboot
      CONDUCTOR
      sudo chmod 0755 #{WRAPPERS.join(' ')}
      sudo chown root:root #{WRAPPERS.join(' ')}
      echo '#{user} ALL=(root) NOPASSWD: #{WRAPPERS.join(', ')}' | sudo tee #{SUDOERS_FILE} >/dev/null
      sudo chmod 0440 #{SUDOERS_FILE}
    SH
  end

  def remediation(server)
    user = server.ssh_user_or_default
    "Conductor needs passwordless sudo to run privileged ops as '#{user}', but this " \
    "server isn't set up yet (sudo: a password is required).\n\n" \
    "Run this once as root (or a sudo user) on the server. It installs a few root-owned " \
    "wrapper scripts and grants passwordless sudo ONLY on those — no blanket sudo, no " \
    "shell escape, no permanent root SSH:\n\n" \
    "#{grant_command(server)}\n\n" \
    "Then retry. See /docs/privileged-ops for the why."
  end
end
