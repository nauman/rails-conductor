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
  NET_DIAGNOSE     = "#{WRAPPER_DIR}/conductor-net-diagnose".freeze              # read-only host network state
  UNBAN_CLOUDFLARE = "#{WRAPPER_DIR}/conductor-unban-cloudflare".freeze          # confirm-gated, Cloudflare ranges only
  WRAPPERS         = [ CHECK, SECURITY_UPDATES, ALL_UPDATES, REBOOT, RECLAIM_SWAP,
                       NET_DIAGNOSE ].freeze

  # HELD PENDING AN INDEPENDENT ADVERSARIAL AUDIT (codex rate-limited until
  # 2026-09-27). Listed here rather than deleted so the audit has the exact script
  # to review and the tests keep exercising it.
  #
  # Being in this list and not WRAPPERS means it is NEVER WRITTEN to a host and
  # never named in the sudoers grant — the capability does not exist on any box.
  # Hiding the MCP action alone would not hold anything: the wrapper would still
  # be installed root-owned on every server the next time anything elevated.
  #
  # To release it: move the constant into WRAPPERS and drop the guard in
  # UnbanCloudflareTool. Two lines, once someone who did not write it has looked.
  WRAPPERS_PENDING_AUDIT = [ UNBAN_CLOUDFLARE ].freeze
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

    begin
      missing = missing_wrappers(ssh)
    rescue InventoryUnavailable => e
      return Probe.new(status: :unreachable, missing: [], detail: "wrapper inventory failed: #{e.message}")
    end
    return Probe.new(status: :ready, missing: [], detail: nil) if missing.empty?

    Probe.new(status: :wrappers_missing, missing: missing,
              detail: "installed before #{missing.join(', ')} existed")
  end

  # The grant is only as good as the wrappers it names. Checking CHECK alone
  # reported "ready" on a box missing four of the five, which is exactly how a
  # privileged op fails at the moment it is needed rather than when it is checked.
  # Raises rather than returning [] on a failed probe: "the inventory did not run"
  # and "nothing is missing" are opposite facts, and collapsing them meant a broken
  # connection reported a healthy box.
  class InventoryUnavailable < StandardError; end

  def missing_wrappers(ssh)
    listing = ssh.execute_with_status("for w in #{WRAPPERS.join(' ')}; do [ -x \"$w\" ] || echo \"$w\"; done")
    raise InventoryUnavailable, listing[:stderr].to_s unless listing[:success]

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
    return false unless res[:success]

    # Verify by USING the grant, not by listing files. Executable paths prove
    # nothing about whether sudo will accept them.
    ssh.execute_with_status("sudo -n #{CHECK}")[:success] && missing_wrappers(ssh).empty?
  rescue InventoryUnavailable
    false
  end

  def unreachable?(stderr)
    stderr.match?(/Connection (refused|timed out|closed)|No route to host|Host key|Permission denied \(publickey|Could not resolve|No SSH key|No IP address/i)
  end

  # One-time, root-run setup: writes the wrapper scripts (root-owned, 0755 — not
  # writable by the deploy user) and a sudoers rule granting NOPASSWD on exactly
  # those wrappers for this server's SSH user. No permanent root SSH; no shell escape.

  # The script for a wrapper that is built and tested but not yet installed.
  # Kept renderable so the audit reviews what would ship, not a description of it.
  # Test seam: run a block with a different pending-audit set. Exists so a held
  # capability's own logic stays covered while it is held.
  def stub_const_pending_audit(list)
    original = WRAPPERS_PENDING_AUDIT
    send(:remove_const, :WRAPPERS_PENDING_AUDIT)
    const_set(:WRAPPERS_PENDING_AUDIT, list.freeze)
    yield
  ensure
    send(:remove_const, :WRAPPERS_PENDING_AUDIT)
    const_set(:WRAPPERS_PENDING_AUDIT, original)
  end

  def pending_wrapper_script(path)
    raise ArgumentError, "#{path} is not pending audit" unless WRAPPERS_PENDING_AUDIT.include?(path)

    <<~SH
        #!/bin/sh
        # Unban every fail2ban entry that falls inside Cloudflare's published ranges,
        # and add those ranges to ignoreip so it cannot recur.
        #
        # THE WRAPPER DECIDES WHAT COUNTS AS CLOUDFLARE. It takes no arguments and
        # fetches the ranges itself. If the caller supplied the address list, the
        # confirm-gate would be theatre: anything could be unbanned by naming it. The
        # only way "Cloudflare only" is a guarantee rather than a hope is for the
        # privileged side to derive it.
        #
        # FAILS CLOSED. If the ranges cannot be fetched or do not look like CIDRs,
        # nothing is unbanned. A stale or empty list must never widen to "unban
        # everything" — that is the failure mode that turns a fix into an incident.
        set -e
        # See conductor-net-diagnose: the jail and address loops use unquoted
        # expansion to word-split fail2ban's output, and unquoted expansion globs.
        # This wrapper ACTS on those values, so closing that edge matters more here.
        set -f

        command -v fail2ban-client >/dev/null 2>&1 || { echo "fail2ban-client not installed" >&2; exit 4; }
        fail2ban-client ping >/dev/null 2>&1 || { echo "fail2ban is not responding" >&2; exit 4; }
        # python3 is not an added dependency: fail2ban is written in Python, so it is
        # present wherever fail2ban is. It gives correct IPv4 AND IPv6 CIDR matching,
        # which shell arithmetic does not.
        command -v python3 >/dev/null 2>&1 || { echo "python3 not available" >&2; exit 4; }

        ranges=$(mktemp) || exit 4
        one=$(mktemp) || exit 4
        trap 'rm -f "$ranges" "$one" "$one.clean"' EXIT INT TERM

        # Validate EACH URL separately, then merge. Appending both to one file and
        # checking the union hides a partial fetch: an empty 200 from one of them
        # leaves a half list that still "looks valid", and the run then reports
        # success having compared bans against half the ranges.
        for u in https://www.cloudflare.com/ips-v4 https://www.cloudflare.com/ips-v6; do
          : >"$one"
          curl -fsS --max-time 15 --proto '=https' --tlsv1.2 "$u" >"$one" || {
            echo "could not fetch $u - refusing to unban anything" >&2; exit 5; }

          # NORMALISE, then validate strictly. Stripping CR, trimming spaces and
          # dropping comments/blank lines costs nothing and removes a silent
          # dependency on a third party never changing its whitespace: today the
          # endpoint serves bare LF, and a switch to CRLF would have made every
          # line fail the CIDR check and the feature refuse forever. Failing closed
          # is the safe direction, but a fix that is dead on arrival is not a fix.
          # Normalising does NOT weaken the check — what remains is validated whole.
          sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e '/^#/d' -e '/^$/d' "$one" >"$one.clean" && mv "$one.clean" "$one"

          # Shape: every remaining line must be a CIDR. A captive portal or an error
          # page answers 200 with HTML, and this is the cheapest way to notice.
          if grep -qvE '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "$one"; then
            echo "$u did not return a CIDR list - refusing to unban anything" >&2; exit 5
          fi

          # PLAUSIBILITY, which shape alone does not give. Cloudflare publishes
          # roughly fifteen IPv4 and seven IPv6 prefixes; a response with one or two
          # lines is a truncated transfer, and a truncated "173.245.48.0/20" becomes
          # "173.245.48.0/2" — a perfectly well-shaped CIDR covering a quarter of the
          # internet. Shape-only validation let 0.0.0.0/0 through and unbanned every
          # address on the box, which is the exact incident this wrapper exists to
          # prevent rather than cause.
          n=$(grep -cE '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "$one") || n=0
          if [ "$n" -lt 4 ]; then
            echo "$u returned only $n prefixes - too few to be the published list; refusing" >&2; exit 5
          fi

          # A prefix broader than anything Cloudflare publishes means the list is not
          # Cloudflare's, whatever it claims. /12 is well below their broadest IPv4
          # block and /32 below their IPv6; anything shorter would exempt swathes of
          # the internet from fail2ban.
          if awk -F/ '$2 == "" { next }
                      /:/  { if ($2 + 0 < 32) exit 1; next }
                             { if ($2 + 0 < 12) exit 1 }' "$one"; then
            :
          else
            echo "$u contains a prefix broader than Cloudflare publishes - refusing to unban anything" >&2
            exit 5
          fi

          cat "$one" >>"$ranges"
          printf '\n' >>"$ranges"
        done

        cidrs=$(grep -E '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "$ranges")
        jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')
        [ -n "$jails" ] || { echo "no jails configured; nothing to do"; exit 0; }

        unbanned=0
        for j in $jails; do
          banned=$(fail2ban-client status "$j" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p')
          for ip in $banned; do
            # A ONE-LINER on purpose. A multi-line python block must start at column
            # 0, which drops the Ruby heredoc's minimum indentation to zero — then
            # <<~ strips nothing, the CONDUCTOR terminators render INDENTED, and sh
            # stops recognising them. That silently breaks every wrapper in this
            # file, not just this one. Caught by rendering and running it.
            #
            # Any exception exits non-zero, which reads as "not a Cloudflare
            # address" and unbans nothing. Failing closed is the right direction.
            if printf '%s\n' "$cidrs" | python3 -c 'import ipaddress,sys; a=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if any(a in ipaddress.ip_network(l.strip(),strict=False) for l in sys.stdin if l.strip()) else 1)' "$ip" 2>/dev/null; then
              if fail2ban-client set "$j" unbanip "$ip" >/dev/null 2>&1; then
                echo "UNBANNED $j $ip"
                unbanned=$(( unbanned + 1 ))
              else
                echo "warning: could not unban $ip from $j" >&2
              fi
            fi
          done

          # Add the ranges to ignoreip so the ban cannot recur. Done per jail and
          # tolerantly: an older fail2ban without addignoreip should not fail the
          # whole run after addresses were already released.
          for c in $cidrs; do
            fail2ban-client set "$j" addignoreip "$c" >/dev/null 2>&1 || true
          done
        done

        # "ban(s)", not "address(es)". A ban is per jail per address, so the same
        # address released from three jails is three bans — reporting that as
        # "3 addresses" tells the reader the box was in worse shape than it was.
        echo "released ${unbanned} ban(s) inside Cloudflare ranges"
        echo "NOTE: ignoreip changes are RUNTIME only - add them to jail.local to survive a restart"
        exit 0
    SH
  end

  def grant_command(server, user: nil)
    user ||= server.ssh_user_or_default
    raise UnsafeUser, "refusing to build a sudoers grant for #{user.inspect}" unless user.to_s.match?(SAFE_USER)

    <<~SH.strip
      # Fail-closed. Without this a failed `visudo -cf` did not stop the `mv` that
      # follows it, so the validation step this file advertises was decorative and
      # an invalid sudoers file could still be installed.
      set -e
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

      # A host-side lock, because it is the only guard that survives the CALLER
      # dying. Ruby-side checks cannot stop a second swapoff started by another
      # worker, another Conductor instance, or a human on the box — and a second
      # swapoff landing on top of the first is how a device gets shed.
      exec 9>/var/lock/conductor-reclaim-swap.lock
      flock -n 9 || { echo "another reclaim is already running on this host" >&2; exit 6; }

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
      sudo tee #{NET_DIAGNOSE} >/dev/null <<'CONDUCTOR'
      #!/bin/sh
      # Read-only host network state — the three questions every 522 investigation
      # ends on, which Conductor previously could not ask: who is banned, what is
      # the firewall doing, and is the box dropping connections before anything
      # sees them.
      #
      # Reads only. It changes nothing, takes no arguments, and every section is
      # optional: a box without fail2ban, ufw or conntrack still produces a useful
      # report rather than a failure. A diagnostic that exits non-zero because one
      # tool is absent is a diagnostic nobody runs during an incident.
      #
      # Deliberately does NOT fetch Cloudflare's ranges. That comparison happens in
      # Conductor, where it can be cached and audited; a root-owned wrapper that
      # reaches out to the internet is a much larger surface than one that prints
      # local state, and it would be doing it on every call.

      # Disable globbing. Both loops below word-split fail2ban's output with an
      # UNQUOTED expansion, which is how you iterate it — but unquoted expansion
      # also globs, so a jail or address containing * or ? would expand against
      # the filesystem. Command substitution inside those values is NOT re-evaluated
      # by POSIX sh, so this is the remaining edge, and it costs one line to close.
      set -f

      section() { printf '\n=== %s ===\n' "$1"; }

      section "fail2ban"
      if command -v fail2ban-client >/dev/null 2>&1; then
        if ! fail2ban-client ping >/dev/null 2>&1; then
          echo "fail2ban is installed but not responding"
        else
          jails=$(fail2ban-client status 2>/dev/null \
                  | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')
          if [ -z "$jails" ]; then
            echo "no jails configured"
          else
            for j in $jails; do
              # Print one BANNED line per address so the caller parses a stable
              # shape instead of fail2ban's prose, which differs across versions.
              banned=$(fail2ban-client status "$j" 2>/dev/null \
                       | sed -n 's/.*Banned IP list:[[:space:]]*//p')
              count=$(fail2ban-client status "$j" 2>/dev/null \
                      | sed -n 's/.*Currently banned:[[:space:]]*//p' | head -n1)
              echo "JAIL $j currently_banned=${count:-unknown}"
              for ip in $banned; do echo "BANNED $j $ip"; done
              ignore=$(fail2ban-client get "$j" ignoreip 2>/dev/null | tr -d '\n')
              [ -n "$ignore" ] && echo "IGNOREIP $j $ignore"
            done
          fi
        fi
      else
        echo "fail2ban-client not installed"
      fi

      section "ufw"
      if command -v ufw >/dev/null 2>&1; then
        ufw status numbered 2>/dev/null || echo "ufw status unavailable"
      else
        echo "ufw not installed"
      fi

      section "edge containers"
      if command -v docker >/dev/null 2>&1; then
        # Say "none" explicitly. An empty section reads as "not checked", and on a
        # box whose edge container has died that is the single most important line
        # in the report.
        edge=$(docker ps --filter name=kamal-proxy --filter name=caddy \
          --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null) || edge=""
        if [ -n "$edge" ]; then
          printf '%s\n' "$edge"
        else
          echo "no kamal-proxy or caddy container is running"
        fi
      else
        echo "docker not installed"
      fi

      section "conntrack"
      # A full conntrack table drops new connections SILENTLY: the app sees nothing,
      # the edge sees a timeout, and it looks exactly like a 522.
      cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
      cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
      if [ -n "$cc" ] && [ -n "$cm" ]; then
        echo "CONNTRACK count=$cc max=$cm"
        # Integer percentage; no bc, which is not installed everywhere.
        [ "$cm" -gt 0 ] && echo "CONNTRACK percent=$(( cc * 100 / cm ))"
      else
        echo "conntrack accounting not available"
      fi

      section "listen queue"
      # Overflows and drops are the kernel refusing connections before any process
      # accepts them — the other silent cause of an edge-side timeout.
      if command -v nstat >/dev/null 2>&1; then
        # -s suppresses the HISTORY WRITE. Without it nstat creates /tmp/.nstat.u0
        # as root, from a wrapper the deploy user triggers — the root-owned-file
        # problem this repo has been bitten by before. -a reads without resetting.
        nstat -asz 2>/dev/null | grep -Ei 'ListenOverflows|ListenDrops|TcpExtSyn' \
          || echo "no listen overflow counters reported"
      else
        grep -E '^(ListenOverflows|ListenDrops)' /proc/net/netstat 2>/dev/null \
          || echo "nstat not installed"
      fi
      exit 0
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
