# A deeper health read than ServerMetrics (which is just cpu/mem/disk gauges):
# one SSH round-trip that probes universal Linux signals and grades each as
# ok / warn / fail, then rolls them up to healthy / degraded / critical.
#
# Deliberately makes NO assumptions about what the server runs (no docker/rails
# specifics) so it works for any host — thresholds are sensible defaults.
class ServerHealth
  Check  = Struct.new(:key, :label, :status, :detail, keyword_init: true)
  Result = Struct.new(:status, :checks, :error, keyword_init: true) do
    def ok?      = error.nil?
    def healthy? = status == :healthy
  end

  # Emits KEY:VALUE lines. Each probe degrades gracefully to a safe value.
  PROBE = <<~BASH.freeze
    echo "DISK_ROOT:$(df -P / | awk 'NR==2{print $5}' | tr -d '%' 2>/dev/null || echo 0)"
    echo "MEM_AVAIL_PCT:$(free | awk 'NR==2{ if($2>0) printf "%d", $7/$2*100; else print 100 }' 2>/dev/null || echo 100)"
    echo "LOAD1:$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)"
    echo "CORES:$(nproc 2>/dev/null || echo 1)"
    echo "SWAP_USED_PCT:$(free | awk 'NR==3{ if($2>0) printf "%d", $3/$2*100; else print 0 }' 2>/dev/null || echo 0)"
    echo "FAILED_UNITS:$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
    echo "REBOOT_REQUIRED:$([ -f /var/run/reboot-required ] && echo yes || echo no)"
    echo "UPTIME:$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d'.' -f1 || echo 0)"
  BASH

  attr_reader :server, :error

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
    @error = nil
  end

  def check
    return failure("SSH not configured") unless server.ssh_configured?

    output = @ssh.execute(PROBE)
    return failure(@ssh.error.presence || "No response from server") unless @ssh.success?

    grade(parse(output))
  end

  # Convenience for the rollup status used by badges.
  def self.status_for(server)
    new(server).check.status
  end

  private

  def parse(output)
    output.to_s.lines.each_with_object({}) do |line, h|
      key, _, val = line.strip.partition(":")
      h[key] = val unless key.empty?
    end
  end

  def grade(p)
    checks = []
    checks << pct_check(:disk_root, "Disk (/)", p["DISK_ROOT"], warn: 80, fail: 90, suffix: "% used")
    # Memory: low available is bad, so invert (warn when available drops low).
    checks << low_check(:mem_avail, "Memory available", p["MEM_AVAIL_PCT"], warn: 15, fail: 5, suffix: "% free")
    checks << load_check(p["LOAD1"], p["CORES"])
    checks << pct_check(:swap, "Swap used", p["SWAP_USED_PCT"], warn: 50, fail: 90, suffix: "% used")
    checks << units_check(p["FAILED_UNITS"])
    checks << reboot_check(p["REBOOT_REQUIRED"])

    rollup = if checks.any? { |c| c.status == :fail } then :critical
    elsif checks.any? { |c| c.status == :warn } then :degraded
    else :healthy
    end

    Result.new(status: rollup, checks: checks, error: nil)
  end

  def pct_check(key, label, raw, warn:, fail:, suffix:)
    v = raw.to_i
    status = v >= fail ? :fail : (v >= warn ? :warn : :ok)
    Check.new(key: key, label: label, status: status, detail: "#{v}#{suffix}")
  end

  def low_check(key, label, raw, warn:, fail:, suffix:)
    v = raw.to_i
    status = v <= fail ? :fail : (v <= warn ? :warn : :ok)
    Check.new(key: key, label: label, status: status, detail: "#{v}#{suffix}")
  end

  def load_check(load_raw, cores_raw)
    load = load_raw.to_f
    cores = [cores_raw.to_i, 1].max
    per_core = load / cores
    status = per_core >= 2.0 ? :fail : (per_core >= 1.0 ? :warn : :ok)
    Check.new(key: :load, label: "Load (1m)", status: status,
              detail: "#{load.round(2)} over #{cores} core#{'s' if cores != 1}")
  end

  def units_check(raw)
    n = raw.to_i
    Check.new(key: :failed_units, label: "Failed services", status: n.zero? ? :ok : :warn,
              detail: n.zero? ? "none" : "#{n} failed unit#{'s' if n != 1}")
  end

  def reboot_check(raw)
    pending = raw.to_s.strip == "yes"
    Check.new(key: :reboot, label: "Reboot", status: pending ? :warn : :ok,
              detail: pending ? "required" : "not required")
  end

  def failure(message)
    @error = message
    Result.new(status: :unknown, checks: [], error: message)
  end
end
