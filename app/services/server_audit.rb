# Read-only security + patch posture audit for a server, over SSH. Complements
# ServerMetrics (gauges) and ServerHealth (resource pressure): this grades the
# hardening/patch state — firewall, fail2ban, SSH hardening, pending security
# updates, reboot-required, auto-upgrades, and public DB exposure — into
# ok/warn/fail, rolled up to secure/attention/at_risk. Nothing is changed.
class ServerAudit
  Check  = Struct.new(:key, :label, :status, :detail, keyword_init: true)
  Result = Struct.new(:status, :checks, :error, keyword_init: true) do
    def ok? = error.nil?
    def secure? = status == :secure
  end

  # One SSH round-trip. Privileged probes use `sudo -n` (fails closed to blank
  # rather than hanging); each degrades to an empty/unknown value.
  # SUDO and PROBE_END exist so a probe that could not LOOK is distinguishable from
  # one that looked and found something. Every privileged line below degrades to
  # blank, and blank used to grade as the insecure answer — so a box without
  # passwordless sudo graded `at_risk` exactly like a box with its firewall off, and
  # DeployPreflight blocks on that.
  PROBE = <<~BASH.freeze
    echo "SUDO:$(sudo -n true 2>/dev/null && echo yes || echo no)"
    SSHD=$(sudo -n sshd -T 2>/dev/null)
    echo "UFW:$(sudo -n ufw status 2>/dev/null | awk 'NR==1{print $2}')"
    echo "FAIL2BAN:$(systemctl is-active fail2ban 2>/dev/null)"
    echo "SSH_ROOT:$(echo "$SSHD" | awk '/^permitrootlogin/{print $2}')"
    echo "SSH_PASSWORD:$(echo "$SSHD" | awk '/^passwordauthentication/{print $2}')"
    echo "SEC_UPDATES:$(apt-get -s upgrade 2>/dev/null | grep '^Inst' | grep -ic security)"
    echo "UPDATES:$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst')"
    echo "REBOOT:$([ -f /var/run/reboot-required ] && echo yes || echo no)"
    echo "AUTOUPGRADE:$(systemctl is-active unattended-upgrades 2>/dev/null)"
    echo "DB_PUBLIC:$(sudo -n ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '0\\.0\\.0\\.0:(5432|3306|6379)' | head -1)"
    echo "PROBE_END:ok"
  BASH

  # Values that are only knowable with passwordless sudo. If sudo is unavailable
  # these are blank for a reason that has nothing to do with the host's posture.
  PRIVILEGED_KEYS = %w[UFW SSH_ROOT SSH_PASSWORD DB_PUBLIC].freeze

  attr_reader :server, :error

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
    @error = nil
  end

  def audit
    return failure("SSH not configured") unless server.ssh_configured?

    output = @ssh.execute(PROBE)
    return failure(@ssh.error.presence || "No response from server") unless @ssh.success?

    grade_output(output)
  end

  # Grade a PROBE's raw output without running SSH — for a batched single-session
  # read (server-detail runs health+audit+storage+sudo over one connection).
  def grade_output(output) = grade(parse(output))

  private

  def parse(output)
    output.to_s.lines.each_with_object({}) do |line, h|
      key, _, val = line.strip.partition(":")
      h[key] = val unless key.empty?
    end
  end

  # INCONCLUSIVE IS NOT A GRADE. Returning a statusless Result routes through the
  # same path as an SSH failure: ServerAuditCheckJob refuses to write it, so the
  # previous grade and timestamp stand and staleness is allowed to accrue visibly
  # (ADR 0010 — fail toward stale, never toward a fresh wrong answer).
  def inconclusive(reason) = Result.new(status: nil, checks: [], error: reason)

  def grade(p)
    return inconclusive("audit probe incomplete — output ended early, so posture is unknown") if p["PROBE_END"] != "ok"

    if p["SUDO"] == "no"
      return inconclusive("no passwordless sudo on this host, so #{PRIVILEGED_KEYS.join(', ')} could not be read — " \
                          "posture is unknown, not insecure. Run conductor_server action=harden to grant the scoped sudo.")
    end

    checks = [
      check(:firewall,     "Firewall (ufw)",        p["UFW"] == "active",         "active", (p["UFW"].presence || "inactive")),
      check(:fail2ban,     "fail2ban",              p["FAIL2BAN"] == "active",    "active", "not running", level: :warn),
      ssh_root_check(p["SSH_ROOT"]),
      check(:ssh_password, "SSH password auth",     p["SSH_PASSWORD"] == "no",    "disabled (key-only)", "ENABLED"),
      check(:db_exposure,  "Database exposure",     p["DB_PUBLIC"].to_s.strip.empty?, "not internet-facing", "PUBLIC: #{p['DB_PUBLIC']}"),
      # Pending security updates are *attention*, not *at_risk*: patches are worth
      # applying, but a pending patch is not active exposure. Blocking a deploy on
      # them couples every ship to host patch state — so warn, don't block. The
      # things that DO block below are active exposure (root login, password auth,
      # public DB, firewall off).
      check(:security_updates, "Security updates",  p["SEC_UPDATES"].to_i.zero?,  "none pending", "#{p['SEC_UPDATES']} pending", level: :warn),
      check(:auto_upgrades, "Automatic updates",    p["AUTOUPGRADE"] == "active", "active", "off", level: :warn),
      check(:reboot,       "Reboot",                p["REBOOT"].to_s.strip != "yes", "not required", "required", level: :warn),
      info(:updates,       "Other updates",         "#{p['UPDATES'].to_i} upgradable")
    ]

    rollup = if checks.any? { |c| c.status == :fail } then :at_risk
    elsif checks.any? { |c| c.status == :warn } then :attention
    else :secure
    end

    Result.new(status: rollup, checks: checks, error: nil)
  end

  # Root SSH login is graded on THREE states, not two: fully off is best, but
  # key-only (`prohibit-password`, reported by sshd as `without-password`) is a
  # defensible posture — no password brute-force — so it's a warn (attention),
  # not an at-risk fail. Password-allowed root (`yes`) stays a fail (active
  # exposure). This lets an operator keep key-only root without the box grading
  # at_risk and blocking every deploy.
  def ssh_root_check(val)
    case val
    when "no"
      Check.new(key: :ssh_root, label: "SSH root login", status: :ok, detail: "disabled")
    when "without-password", "prohibit-password"
      Check.new(key: :ssh_root, label: "SSH root login", status: :warn, detail: "key-only (no password)")
    else
      Check.new(key: :ssh_root, label: "SSH root login", status: :fail, detail: (val.presence || "ENABLED"))
    end
  end

  def check(key, label, ok, ok_detail, bad_detail, level: :fail)
    Check.new(key: key, label: label, status: ok ? :ok : level, detail: ok ? ok_detail : bad_detail)
  end

  def info(key, label, detail)
    Check.new(key: key, label: label, status: :info, detail: detail)
  end

  def failure(message)
    @error = message
    Result.new(status: :unknown, checks: [], error: message)
  end
end
