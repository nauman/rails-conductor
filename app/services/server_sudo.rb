# Least-privilege privileged-ops setup. Fleet ops (updates, reboot) need root; we
# run them as the SSH user via `sudo -n`. Rather than granting NOPASSWD on general
# tools like apt-get (a documented GTFOBins shell-escape — /docs/privileged-ops),
# Conductor grants NOPASSWD ONLY on a few root-owned wrapper scripts that hardcode
# the exact operation with no argument passthrough. The deploy user can trigger the
# vetted actions but cannot inject flags or spawn a root shell.
#
# ROOT IS NEEDED ONCE, AT REGISTRATION, AND NEVER AGAIN. HardenServer's PROVISION
# step grants `deploy ALL=(ALL) NOPASSWD:ALL`, so on any Conductor-provisioned box
# the deploy user can already install these wrappers itself. That is what makes
# #repair! possible: when Conductor gains a new privileged op, the boxes catch up
# on their own instead of queueing a root SSH session for a human. Treating a
# missing wrapper as "go log in as root" was a design mistake, not a constraint.
module ServerSudo
  module_function

  WRAPPER_DIR      = "/usr/local/sbin".freeze
  CHECK            = "#{WRAPPER_DIR}/conductor-check".freeze                    # no-op readiness probe
  SECURITY_UPDATES = "#{WRAPPER_DIR}/conductor-apply-security-updates".freeze
  ALL_UPDATES      = "#{WRAPPER_DIR}/conductor-apply-all-updates".freeze
  REBOOT           = "#{WRAPPER_DIR}/conductor-reboot".freeze
  RECLAIM_SWAP     = "#{WRAPPER_DIR}/conductor-reclaim-swap".freeze
  WRAPPERS         = [ CHECK, SECURITY_UPDATES, ALL_UPDATES, REBOOT, RECLAIM_SWAP ].freeze
  SUDOERS_FILE     = "/etc/sudoers.d/conductor".freeze

  # A Unix account name. Validated because #grant_command interpolates it into a
  # root-run shell command AND into a sudoers file: a quote or newline here turns
  # an operator pasting the setup block into an injection, and a merely malformed
  # value writes a sudoers file that locks every privileged op out.
  SAFE_USER = /\A[a-z_][a-z0-9_-]{0,31}\z/

  class UnsafeUser < StandardError; end

  # Why a probe and not a boolean: "cannot reach the host", "sudo wants a password",
  # and "the grant is fine but this wrapper was added after you provisioned" need
  # three different answers. Collapsing them into false meant every SSH hiccup told
  # the operator to go re-run a root setup block they did not need.
  Probe = Struct.new(:status, :missing, :detail, keyword_init: true) do
    def ready? = status == :ready
    def repairable? = status == :wrappers_missing
  end

  def probe(ssh)
    res = ssh.execute_with_status("sudo -n #{CHECK}")
    unless res[:success] && res[:exit_code].to_i.zero?
      stderr = res[:stderr].to_s
      return Probe.new(status: :unreachable, missing: [], detail: stderr.presence || "host did not answer") if unreachable?(stderr)
      return Probe.new(status: :no_grant, missing: WRAPPERS, detail: stderr.presence || "sudo -n #{CHECK} failed")
    end

    missing = missing_wrappers(ssh)
    return Probe.new(status: :ready, missing: [], detail: nil) if missing.empty?

    Probe.new(status: :wrappers_missing, missing: missing,
              detail: "installed before #{missing.join(', ')} existed")
  end

  # The grant is only as good as the wrappers it names. Checking CHECK alone
  # reported "ready" on a box missing four of the five, which is exactly how a
  # privileged op fails at the moment it is needed rather than when it is checked.
  def missing_wrappers(ssh)
    listing = ssh.execute_with_status("for w in #{WRAPPERS.join(' ')}; do [ -x \"$w\" ] || echo \"$w\"; done")
    return [] unless listing[:success]

    raw = listing[:stdout].presence || listing[:output]
    raw.to_s.split("\n").map(&:strip).select { |w| WRAPPERS.include?(w) }
  end

  def ready?(ssh) = probe(ssh).ready?

  # THE ONE DOOR. Every privileged op goes through here, and it exists so that no
  # caller can decide on its own to send a human to a root prompt.
  #
  # The mistake it prevents is specific and was made in this file: `no_grant` reads
  # like "this box needs root", and it does not. It means the SCOPED sudoers file
  # is missing — while /etc/sudoers.d/90-deploy from provisioning may still grant
  # the deploy user everything. So the escalation is always attempted with the
  # identity Conductor already holds BEFORE anyone is asked for a credential. A
  # human is the last resort, reached only after the automated path has actually
  # been tried and actually failed.
  Elevation = Struct.new(:status, :detail, keyword_init: true) do
    def usable? = %i[ready repaired].include?(status)
    def needs_operator? = status == :needs_operator
  end

  def ensure!(server, ssh)
    probe = probe(ssh)
    return Elevation.new(status: :ready) if probe.ready?
    return Elevation.new(status: :unreachable, detail: probe.detail) if probe.status == :unreachable

    # Both :wrappers_missing and :no_grant are repairable with the deploy user's
    # own sudo. Try, then report — never the other way round.
    return Elevation.new(status: :repaired, detail: "installed #{probe.missing.join(', ')}") if repair!(server, ssh)

    Elevation.new(status: :needs_operator, detail: remediation(server))
  end

  # Bring a box's wrapper set up to date USING THE DEPLOY USER'S OWN SUDO. No root
  # login, no human, no pasted block. Idempotent — grant_command rewrites all of
  # them every time, so this doubles as drift repair.
  def repair!(server, ssh)
    res = ssh.execute_with_status(grant_command(server))
    return true if res[:success] && missing_wrappers(ssh).empty?

    false
  end

  def unreachable?(stderr)
    stderr.match?(/Connection (refused|timed out|closed)|No route to host|Host key|Permission denied \(publickey|Could not resolve|No SSH key|No IP address/i)
  end

  # One-time, root-run setup: writes the wrapper scripts (root-owned, 0755 — not
  # writable by the deploy user) and a sudoers rule granting NOPASSWD on exactly
  # those wrappers for this server's SSH user. No permanent root SSH; no shell escape.
  def grant_command(server, user: nil)
    user ||= server.ssh_user_or_default
    raise UnsafeUser, "refusing to build a sudoers grant for #{user.inspect}" unless user.to_s.match?(SAFE_USER)

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
      sudo tee #{RECLAIM_SWAP} >/dev/null <<'CONDUCTOR'
      #!/bin/sh
      # Force swapped-out pages back into RAM, then put swap back exactly as it was.
      #
      # The guard is the point of this wrapper. swapoff must place every evacuated
      # page somewhere; run it when RAM is tight and the kernel OOM-kills a live
      # box. Requiring 2x headroom keeps a cosmetic metric from causing an outage,
      # and living here means no caller can pass a flag to skip it.
      set -e

      # Read ONE snapshot and address rows by label. Row-number parsing silently
      # read the wrong line on older procps, and an unreadable `free` left both
      # values empty — which the guard then treated as "0 in swap, nothing to do"
      # and reported as success. A safety check that fails open is not one.
      snapshot=$(free -k 2>/dev/null) || { echo "cannot read memory state" >&2; exit 4; }
      avail=$(echo "$snapshot" | awk '/^Mem:/  {print $7}')
      used=$(echo  "$snapshot" | awk '/^Swap:/ {print $3}')
      case "$avail" in ''|*[!0-9]*) echo "unreadable memory figures from free(1)" >&2; exit 4 ;; esac
      case "$used"  in ''|*[!0-9]*) echo "unreadable swap figures from free(1)"   >&2; exit 4 ;; esac

      if [ "$used" -eq 0 ]; then echo "swap already empty"; exit 0; fi
      if [ "$avail" -lt $(( used * 2 )) ]; then
        echo "refusing: ${used}K in swap but only ${avail}K available RAM" >&2
        exit 3
      fi

      # swapoff -a disables every ACTIVE device; swapon -a only restores what fstab
      # lists. A zram, cloud-init, or hand-added device is not in fstab, so the naive
      # pair silently leaves the box with LESS swap than it started with — the exact
      # opposite of the point. Record what was active and put each one back.
      devices=$(awk 'NR>1 {print $1}' /proc/swaps)
      swapoff -a
      swapon -a 2>/dev/null || true
      for d in $devices; do
        grep -qs "^${d}[[:space:]]" /proc/swaps || swapon "$d" 2>/dev/null || echo "warning: could not restore $d" >&2
      done

      active=$(awk 'NR>1' /proc/swaps | wc -l)
      if [ "$active" -eq 0 ]; then
        echo "ERROR: swap is OFF after reclaim - restore it before this box sees load" >&2
        exit 5
      fi
      echo "reclaimed ${used}K; ${active} swap device(s) active"
      CONDUCTOR
      sudo chmod 0755 #{WRAPPERS.join(' ')}
      sudo chown root:root #{WRAPPERS.join(' ')}
      # Stage, validate, THEN install. An invalid sudoers file written in place locks
      # every privileged op out of the box, and the way back in is the root login
      # this whole design exists to avoid needing.
      echo '#{user} ALL=(root) NOPASSWD: #{WRAPPERS.join(', ')}' | sudo tee #{SUDOERS_FILE}.new >/dev/null
      sudo chmod 0440 #{SUDOERS_FILE}.new
      sudo visudo -cf #{SUDOERS_FILE}.new >/dev/null
      sudo mv #{SUDOERS_FILE}.new #{SUDOERS_FILE}
    SH
  end

  def remediation(server)
    user = server.ssh_user_or_default
    "Conductor needs passwordless sudo to run privileged ops as '#{user}'. It ALREADY " \
    "TRIED to set this up itself using that user's existing sudo, and could not — so this " \
    "box has no working automated path and a human has to open it once.\n\n" \
    "Run this once as root (or a sudo user) on the server. It installs a few root-owned " \
    "wrapper scripts and grants passwordless sudo ONLY on those — no blanket sudo, no " \
    "shell escape, no permanent root SSH:\n\n" \
    "#{grant_command(server)}\n\n" \
    "Then retry. See /docs/privileged-ops for the why."
  end
end
