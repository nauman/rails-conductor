# Hatchbox-style one-shot "provision & harden" — you add Conductor's key to the
# box's root, and Conductor takes it the rest of the way ITSELF. Turns an at-risk
# root-login box into a hardened, deploy-user-managed one WITHOUT ever locking
# Conductor out, by ordering the steps so root access is only surrendered after a
# deploy+sudo identity has been provisioned AND verified over a live connection:
#
#   1. provision   — create the `deploy` user + NOPASSWD sudo + Conductor's key
#                    (runs as the current ssh_user, i.e. root)
#   2. verify      — open a SEPARATE connection as `deploy` and confirm `sudo -n`
#                    works. If not, STOP — root stays enabled, no lockout.
#   3. firewall    — ufw (SSH/HTTP/HTTPS + docker subnets so colocated apps keep
#                    reaching host services) + fail2ban
#   4. close_db    — rebind an exposed host Postgres off 0.0.0.0 to loopback + the
#                    docker bridge gateways (colocated containers keep working)
#   5. ssh_harden  — LAST: PermitRootLogin no + PasswordAuthentication no. The
#                    in-flight root connection completes; future ops use deploy.
#   6. flip        — persist server.ssh_user = deploy so Conductor now manages the
#                    box as deploy+sudo. Re-audit and return the grade.
#
# Every step is idempotent, so a re-run on an already-hardened box is a no-op that
# still returns the current audit grade. The SSH seams are injectable for tests.
class HardenServer
  DEPLOY_USER = "deploy".freeze

  Result = Struct.new(:ok, :steps, :audit_status, :error, keyword_init: true) do
    def ok? = ok
  end

  # Idempotent provisioning + hardening scripts. Bash, sudo-guarded, fail-loud.
  PROVISION = <<~BASH.freeze
    set -e
    id #{DEPLOY_USER} >/dev/null 2>&1 || sudo useradd -m -s /bin/bash #{DEPLOY_USER}
    sudo install -d -m 700 -o #{DEPLOY_USER} -g #{DEPLOY_USER} /home/#{DEPLOY_USER}/.ssh
    # Conductor's key already authorizes root; mirror it to deploy so Conductor can log in as deploy.
    sudo cp /root/.ssh/authorized_keys /home/#{DEPLOY_USER}/.ssh/authorized_keys
    sudo chown #{DEPLOY_USER}:#{DEPLOY_USER} /home/#{DEPLOY_USER}/.ssh/authorized_keys
    sudo chmod 600 /home/#{DEPLOY_USER}/.ssh/authorized_keys
    echo 'deploy ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-deploy >/dev/null
    sudo chmod 440 /etc/sudoers.d/90-deploy
    sudo visudo -cf /etc/sudoers.d/90-deploy >/dev/null
    getent group docker >/dev/null 2>&1 && sudo usermod -aG docker #{DEPLOY_USER} || true
    echo PROVISION_OK
  BASH

  VERIFY = "sudo -n true && echo DEPLOY_SUDO_OK".freeze

  # Operator IPs that must never be fail2ban-banned (a laptop/office the operator
  # SSHes in from). Conductor can't auto-detect these — it only knows its own
  # source IP — so they're configured via CONDUCTOR_FAIL2BAN_ALLOWLIST (space- or
  # comma-separated). Conductor's own connecting IP is always added on top.
  IP_TOKEN = %r{\A(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]+)(?:/\d{1,3})?\z}

  def self.operator_allowlist
    ENV["CONDUCTOR_FAIL2BAN_ALLOWLIST"].to_s.split(/[\s,]+/).grep(IP_TOKEN).join(" ")
  end

  def firewall_script
    <<~BASH
      set -e
      export DEBIAN_FRONTEND=noninteractive
      sudo apt-get install -y -qq ufw fail2ban >/dev/null 2>&1 || true
      sudo ufw allow OpenSSH >/dev/null
      sudo ufw allow 80/tcp >/dev/null
      sudo ufw allow 443/tcp >/dev/null
      # Let containers keep reaching host-bound services (e.g. a colocated Postgres).
      for net in $(docker network ls -q 2>/dev/null | xargs -r docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\\n' | grep -E '^(172|10)\\.' | sort -u); do
        sudo ufw allow from "$net" >/dev/null 2>&1 || true
      done
      # CRITICAL: never let fail2ban ban the IP Conductor connects FROM (or the
      # operator on this session), or a burst of legit ops locks management out of
      # a box Conductor owns. $SSH_CLIENT's first field is Conductor's source IP;
      # the operator's trusted IPs come from CONDUCTOR_FAIL2BAN_ALLOWLIST.
      client_ip="${SSH_CLIENT%% *}"
      sudo mkdir -p /etc/fail2ban/jail.d
      printf '[sshd]\\nignoreip = 127.0.0.1/8 ::1 %s #{self.class.operator_allowlist}\\nbantime = 1h\\n' "$client_ip" | sudo tee /etc/fail2ban/jail.d/00-conductor-allowlist.local >/dev/null
      sudo ufw --force enable >/dev/null
      sudo systemctl enable fail2ban >/dev/null 2>&1 || true
      sudo systemctl restart fail2ban >/dev/null 2>&1 || sudo systemctl start fail2ban >/dev/null 2>&1 || true
      echo FIREWALL_OK
    BASH
  end

  CLOSE_DB = <<~BASH.freeze
    set -e
    changed=0
    for conf in /etc/postgresql/*/main/postgresql.conf; do
      [ -f "$conf" ] || continue
      sudo ss -tlnH 2>/dev/null | awk '{print $4}' | grep -q '0\\.0\\.0\\.0:5432' || continue
      gws=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -E '^(172|10)\\.' | paste -sd, -)
      addrs="localhost${gws:+,$gws}"
      sudo sed -i "s/^[[:space:]]*#\\?[[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '$addrs'/" "$conf"
      changed=1
    done
    if [ "$changed" = 1 ]; then
      # Reboot-safe ordering: Postgres binds the docker bridge gateways, but those
      # only exist AFTER docker starts. On boot Postgres starts first, silently
      # binds localhost only, and colocated containers crashloop (can't reach the
      # DB). Order Postgres after docker so the gateways exist when it binds.
      sudo mkdir -p /etc/systemd/system/postgresql@.service.d
      printf '[Unit]\\nAfter=docker.service\\nWants=docker.service\\n' | sudo tee /etc/systemd/system/postgresql@.service.d/10-after-docker.conf >/dev/null
      sudo systemctl daemon-reload
      sudo systemctl restart postgresql
      sleep 3
    fi
    echo CLOSE_DB_OK
  BASH

  SSH_HARDEN = <<~BASH.freeze
    set -e
    sudo install -d -m 755 /etc/ssh/sshd_config.d
    printf '%s\\n' 'PermitRootLogin no' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'X11Forwarding no' | sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null
    sudo sshd -t
    sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || sudo service ssh reload
    echo SSH_HARDEN_OK
  BASH

  def initialize(server, root_ssh: nil, deploy_ssh: nil, auditor: nil)
    @server        = server
    @provided_root = root_ssh                                                # tests inject the privileged seam
    @deploy_ssh    = deploy_ssh || SshConnection.new(server, user: DEPLOY_USER) # freshly-provisioned identity
    @auditor       = auditor
    @steps         = []
  end

  def call
    return fail!("SSH not configured") unless @server.ssh_configured?
    return fail!("no privileged access to #{@server.name}: add Conductor's key to root@#{@server.ip_address} " \
                 "(the Hatchbox model provisions via root), or ensure the deploy user has passwordless sudo") unless privileged_ssh

    run_root("provision", PROVISION) or return failed_result
    return fail!("deploy+sudo verification failed — root left enabled, no lockout") unless deploy_sudo_ok?

    # Install the vetted ScopedSudo wrappers for the deploy user (while root is
    # still reachable) so privileged ops (apply_updates/reboot) AND the "privileged
    # ops readiness" check work via the least-privilege scoped grant — not just the
    # broad grant provisioning laid down for bootstrapping.
    run_root("grant_sudo_wrappers", ServerSudo.grant_command(@server, user: DEPLOY_USER)) or return failed_result

    run_root("firewall", firewall_script) or return failed_result
    run_root("close_db",  CLOSE_DB)  or return failed_result
    run_root("ssh_harden", SSH_HARDEN) or return failed_result

    @server.update!(ssh_user: DEPLOY_USER)

    audit = (@auditor || ServerAudit.new(@server)).audit
    @server.record_audit!(audit.status) if audit.ok?

    Result.new(ok: true, steps: @steps, audit_status: (audit.ok? ? audit.status : nil), error: nil)
  end

  private

  # The connection used for privileged steps. The server's ssh_user is the
  # app-ops identity (often a deploy user WITHOUT passwordless sudo), which can't
  # bootstrap hardening — so resolve a connection that actually holds privilege:
  #   1. root — the Hatchbox model puts Conductor's key on root; an un-hardened
  #      box still permits root login, so this is the normal path.
  #   2. the deploy user IF it already has passwordless sudo — the case when
  #      re-running harden on an already-hardened box (root is off by then).
  # nil when neither works, so call() aborts with a legible message instead of
  # failing every step with an opaque sudo-password error.
  def privileged_ssh
    return @provided_root if @provided_root
    return @privileged if defined?(@privileged)

    @privileged =
      begin
        root = SshConnection.new(@server, user: "root")
        root.execute("echo ok")
        if root.success?
          root
        else
          du = SshConnection.new(@server, user: DEPLOY_USER)
          du.execute_with_status("sudo -n true")[:success] ? du : nil
        end
      end
  end

  def run_root(name, script)
    res = privileged_ssh.execute_with_status(script)
    @steps << { step: name, ok: res[:success] }
    return true if res[:success]

    @error = "#{name} failed: #{(res[:stderr].presence || res[:output]).to_s.strip[0, 300]}"
    false
  end

  # Verify the freshly-created deploy identity can log in AND sudo, over a live
  # connection — the gate that guarantees disabling root can't lock Conductor out.
  def deploy_sudo_ok?
    res = @deploy_ssh.execute_with_status(VERIFY)
    ok = res[:success] && res[:output].to_s.include?("DEPLOY_SUDO_OK")
    @steps << { step: "verify_deploy_sudo", ok: ok }
    ok
  end

  def failed_result
    Result.new(ok: false, steps: @steps, audit_status: nil, error: @error)
  end

  def fail!(message)
    @error = message
    failed_result
  end
end
